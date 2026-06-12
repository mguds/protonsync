package proton_api_bridge

import (
	"context"
	"fmt"
	"path"

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

func (protonDrive *ProtonDrive) getLinkPath(ctx context.Context, link *proton.Link) (string, error) {
	if link == nil {
		return "", fmt.Errorf("cannot resolve nil link")
	}
	if link.LinkID == protonDrive.RootLink.LinkID {
		return "", nil
	}
	if link.ParentLinkID == "" {
		return "", fmt.Errorf("link %s is outside selected root %s", link.LinkID, protonDrive.RootLink.LinkID)
	}

	parent, err := protonDrive.c.GetLink(ctx, protonDrive.MainShare.ShareID, link.ParentLinkID)
	if err != nil {
		return "", fmt.Errorf("get parent %s for link %s: %w", link.ParentLinkID, link.LinkID, err)
	}
	parentPath, err := protonDrive.getLinkPath(ctx, &parent)
	if err != nil {
		return "", err
	}
	name, err := protonDrive.sharedLinkName(ctx, protonDrive.MainShare, link, protonDrive.MainShareKR)
	if err != nil {
		return "", fmt.Errorf("decrypt event link %s name: %w", link.LinkID, err)
	}
	return path.Join(parentPath, name), nil
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
		change.Path, err = protonDrive.getLinkPath(ctx, &event.Link)
		if err != nil {
			return nil, err
		}
		batch.Changes = append(batch.Changes, change)
	}

	return batch, nil
}
