package protondrive

import (
	"context"
)

// SharedItem describes one top-level entry in Proton Drive "Shared with me".
type SharedItem struct {
	Name     string
	IsFolder bool
}

// ListSharedWithMeItems returns every item currently shared with this account.
// The remote must be a plain protondrive remote (not shared_with_me mode);
// the listing is independent of which share the Fs is anchored to.
func (f *Fs) ListSharedWithMeItems(ctx context.Context) ([]SharedItem, error) {
	items, err := f.protonDrive.ListSharedWithMe(ctx)
	if err != nil {
		return nil, err
	}
	ret := make([]SharedItem, 0, len(items))
	for _, item := range items {
		ret = append(ret, SharedItem{
			Name:     f.opt.Enc.ToStandardName(item.Name),
			IsFolder: item.IsFolder,
		})
	}
	return ret, nil
}
