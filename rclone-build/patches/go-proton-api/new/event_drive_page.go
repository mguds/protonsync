package proton

import "context"

// GetShareEventPage returns a single page of share events after eventID and
// whether more pages follow. The returned EventID is the cursor for the next
// page. Unlike GetShareEvent, which accumulates every page in memory under a
// single context, callers can apply and persist progress page by page.
func (c *Client) GetShareEventPage(ctx context.Context, shareID, eventID string) (DriveEvent, bool, error) {
	return c.getShareEvent(ctx, shareID, eventID)
}
