package proton_api_bridge

import (
	"context"
	"fmt"
	"path"

	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/rclone/go-proton-api"
)

// DriveEventChange is a decrypted change from the selected share event stream.
// Delete events only contain LinkID; callers must retain an ID-to-path index.
type DriveEventChange struct {
	LinkID       string
	ParentLinkID string
	Path         string
	EventType    proton.LinkEventType
	LinkType     proton.LinkType
	LinkState    proton.LinkState
}

// DriveEventBatch contains all events after an anchor ID.
type DriveEventBatch struct {
	EventID string
	Refresh bool
	Changes []DriveEventChange
}

// GetLatestShareEventID returns the current anchor for the selected share.
func (protonDrive *ProtonDrive) GetLatestShareEventID(ctx context.Context) (string, error) {
	return protonDrive.c.GetLatestShareEventID(ctx, protonDrive.MainShare.ShareID)
}

// eventResolver resolves event link paths for one GetShareEvents call. It
// memoizes parent links, node keyrings and folder paths so that a batch of
// events under the same deep folders costs one GetLink per distinct ancestor,
// instead of re-walking the whole parent chain for every ancestor of every
// event (quadratic in depth, times the batch size), which made large batches
// exceed the poll deadline and wedge the event stream.
type eventResolver struct {
	pd     *ProtonDrive
	links  map[string]*proton.Link
	nodeKR map[string]*crypto.KeyRing
	paths  map[string]string
}

func newEventResolver(pd *ProtonDrive) *eventResolver {
	return &eventResolver{
		pd:     pd,
		links:  map[string]*proton.Link{},
		nodeKR: map[string]*crypto.KeyRing{},
		paths:  map[string]string{},
	}
}

func (r *eventResolver) getLink(ctx context.Context, linkID string) (*proton.Link, error) {
	if link, ok := r.links[linkID]; ok {
		return link, nil
	}
	link, err := r.pd.c.GetLink(ctx, r.pd.MainShare.ShareID, linkID)
	if err != nil {
		return nil, err
	}
	r.links[linkID] = &link
	return &link, nil
}

// parentKR mirrors sharedLinkParentKR: the keyring that decrypts link's name
// and node key.
func (r *eventResolver) parentKR(ctx context.Context, link *proton.Link) (*crypto.KeyRing, error) {
	share := r.pd.MainShare
	if link.LinkID == share.LinkID || link.ParentLinkID == "" {
		return r.pd.MainShareKR, nil
	}
	parent, err := r.getLink(ctx, link.ParentLinkID)
	if err != nil {
		return nil, fmt.Errorf("get shared parent link %s in share %s: %w", link.ParentLinkID, share.ShareID, err)
	}
	return r.linkKR(ctx, parent)
}

// linkKR returns the node keyring of a (fetched, memoized) folder link.
func (r *eventResolver) linkKR(ctx context.Context, link *proton.Link) (*crypto.KeyRing, error) {
	if kr, ok := r.nodeKR[link.LinkID]; ok {
		return kr, nil
	}
	parentKR, err := r.parentKR(ctx, link)
	if err != nil {
		return nil, fmt.Errorf("get shared parent keyring for link %s in share %s: %w", link.LinkID, r.pd.MainShare.ShareID, err)
	}
	sigKR, err := r.pd.getSignatureVerificationKeyring(ctx, []string{link.SignatureEmail}, parentKR)
	if err != nil {
		return nil, fmt.Errorf("get shared parent signature keyring for link %s signature email %q: %w", link.LinkID, link.SignatureEmail, err)
	}
	kr, err := link.GetKeyRing(parentKR, sigKR)
	if err != nil {
		return nil, fmt.Errorf("decrypt shared parent link keyring for link %s signature email %q: %w", link.LinkID, link.SignatureEmail, err)
	}
	r.nodeKR[link.LinkID] = kr
	return kr, nil
}

func (r *eventResolver) name(ctx context.Context, link *proton.Link) (string, error) {
	parentKR, err := r.parentKR(ctx, link)
	if err != nil {
		return "", fmt.Errorf("get shared link parent keyring for link %s in share %s: %w", link.LinkID, r.pd.MainShare.ShareID, err)
	}
	sigKR, err := r.pd.getSignatureVerificationKeyring(ctx, []string{link.NameSignatureEmail, link.SignatureEmail}, parentKR)
	if err != nil {
		return "", fmt.Errorf("get shared link name signature keyring for link %s name email %q signature email %q: %w", link.LinkID, link.NameSignatureEmail, link.SignatureEmail, err)
	}
	name, err := link.GetName(parentKR, sigKR)
	if err != nil {
		return "", fmt.Errorf("decrypt shared link name for link %s name email %q signature email %q: %w", link.LinkID, link.NameSignatureEmail, link.SignatureEmail, err)
	}
	return name, nil
}

// linkPath returns link's path relative to the selected root. Paths are
// memoized only for fetched ancestors, never for the event link itself.
func (r *eventResolver) linkPath(ctx context.Context, link *proton.Link, memo bool) (string, error) {
	if link == nil {
		return "", fmt.Errorf("cannot resolve nil link")
	}
	if link.LinkID == r.pd.RootLink.LinkID {
		return "", nil
	}
	if memo {
		if p, ok := r.paths[link.LinkID]; ok {
			return p, nil
		}
	}
	if link.ParentLinkID == "" {
		return "", fmt.Errorf("link %s is outside selected root %s", link.LinkID, r.pd.RootLink.LinkID)
	}
	parent, err := r.getLink(ctx, link.ParentLinkID)
	if err != nil {
		return "", fmt.Errorf("get parent %s for link %s: %w", link.ParentLinkID, link.LinkID, err)
	}
	parentPath, err := r.linkPath(ctx, parent, true)
	if err != nil {
		return "", err
	}
	name, err := r.name(ctx, link)
	if err != nil {
		return "", fmt.Errorf("decrypt event link %s name: %w", link.LinkID, err)
	}
	p := path.Join(parentPath, name)
	if memo {
		r.paths[link.LinkID] = p
	}
	return p, nil
}

// GetShareEvents returns decrypted changes after eventID for the selected share.
func (protonDrive *ProtonDrive) GetShareEvents(ctx context.Context, eventID string) (*DriveEventBatch, error) {
	events, err := protonDrive.c.GetShareEvent(ctx, protonDrive.MainShare.ShareID, eventID)
	if err != nil {
		return nil, err
	}

	batch := &DriveEventBatch{
		EventID: events.EventID,
		Refresh: bool(events.Refresh),
		Changes: make([]DriveEventChange, 0, len(events.Events)),
	}
	if batch.Refresh {
		protonDrive.ClearCache()
		return batch, nil
	}

	resolver := newEventResolver(protonDrive)
	for i := range events.Events {
		event := &events.Events[i]
		change := DriveEventChange{
			EventType: event.EventType,
			LinkID:    event.Link.LinkID,
			LinkType:  event.Link.Type,
			LinkState: event.Link.State,
		}
		if event.EventType == proton.LinkEventDelete {
			protonDrive.removeLinkIDFromCache(change.LinkID, true)
			batch.Changes = append(batch.Changes, change)
			continue
		}

		change.ParentLinkID = event.Link.ParentLinkID
		protonDrive.removeLinkIDFromCache(change.LinkID, true)
		change.Path, err = resolver.linkPath(ctx, &event.Link, false)
		if err != nil {
			return nil, err
		}
		batch.Changes = append(batch.Changes, change)
	}

	return batch, nil
}
