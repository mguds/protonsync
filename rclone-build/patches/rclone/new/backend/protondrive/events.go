package protondrive

import (
	"context"
	"errors"
	"fmt"
	"path"
	"strings"

	"github.com/rclone/go-proton-api"
)

var errEventOutsideRoot = errors.New("event is outside remote root")

// EventChange is a decrypted Proton Drive event relative to this Fs root.
// Delete events intentionally have no path because Proton only sends LinkID.
type EventChange struct {
	LinkID    string
	Path      string
	IsDir     bool
	IsDeleted bool
}

// EventBatch contains all changes after an event anchor.
type EventBatch struct {
	EventID string
	Refresh bool
	Changes []EventChange
}

// LatestEventID returns the current event anchor for this Proton share.
func (f *Fs) LatestEventID(ctx context.Context) (string, error) {
	return f.protonDrive.GetLatestShareEventID(ctx)
}

func (f *Fs) eventPath(remotePath string) (string, error) {
	remotePath = f.opt.Enc.ToStandardPath(remotePath)
	root := strings.Trim(f.root, "/")
	if root == "" {
		return strings.Trim(remotePath, "/"), nil
	}
	if remotePath == root {
		return "", nil
	}
	prefix := root + "/"
	if !strings.HasPrefix(remotePath, prefix) {
		return "", fmt.Errorf("%w: path %q root %q", errEventOutsideRoot, remotePath, root)
	}
	return strings.TrimPrefix(remotePath, prefix), nil
}

// PollEvents returns changes after eventID.
func (f *Fs) PollEvents(ctx context.Context, eventID string) (*EventBatch, error) {
	source, err := f.protonDrive.GetShareEvents(ctx, eventID)
	if err != nil {
		return nil, err
	}
	batch := &EventBatch{
		EventID: source.EventID,
		Refresh: source.Refresh,
		Changes: make([]EventChange, 0, len(source.Changes)),
	}
	if batch.Refresh {
		return batch, nil
	}

	for _, sourceChange := range source.Changes {
		change := EventChange{
			LinkID: sourceChange.LinkID,
			IsDir:  sourceChange.LinkType == proton.LinkTypeFolder,
			IsDeleted: sourceChange.EventType == proton.LinkEventDelete ||
				sourceChange.LinkState != proton.LinkStateActive,
		}
		if !change.IsDeleted {
			change.Path, err = f.eventPath(path.Clean(sourceChange.Path))
			if err != nil {
				if errors.Is(err, errEventOutsideRoot) {
					continue
				}
				return nil, err
			}
		}
		batch.Changes = append(batch.Changes, change)
	}
	return batch, nil
}

var _ interface {
	LatestEventID(context.Context) (string, error)
	PollEvents(context.Context, string) (*EventBatch, error)
} = (*Fs)(nil)
