// Package protonwatch downloads Proton Drive changes from the share event stream.
package protonwatch

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/rclone/rclone/backend/protondrive"
	"github.com/rclone/rclone/cmd"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/flags"
	"github.com/rclone/rclone/fs/operations"
	"github.com/rclone/rclone/fs/walk"
	"github.com/spf13/cobra"
)

type indexedItem struct {
	Path  string `json:"path"`
	IsDir bool   `json:"is_dir"`
}

type watcherState struct {
	Remote  string                 `json:"remote"`
	EventID string                 `json:"event_id"`
	Items   map[string]indexedItem `json:"items"`
}

type eventSource interface {
	LatestEventID(context.Context) (string, error)
	PollEvents(context.Context, string) (*protondrive.EventBatch, error)
}

var (
	pollInterval   = fs.Duration(15 * time.Second)
	stateFile      string
	lockFile       string
	fallbackMarker string
	dirtyDir       string
	suppressDir    string
	recoveryDir    string
	healthFile     string
)

func init() {
	cmd.Root.AddCommand(commandDefinition)
	commandFlags := commandDefinition.Flags()
	flags.FVarP(commandFlags, &pollInterval, "poll-interval", "", "Time between Proton event polls", "")
	commandFlags.StringVar(&stateFile, "state-file", "", "Persistent event anchor and link index")
	commandFlags.StringVar(&lockFile, "lock-file", "", "Advisory lock shared with bisync and local uploads")
	commandFlags.StringVar(&fallbackMarker, "fallback-marker", "", "File to create when a full bisync is required")
	commandFlags.StringVar(&dirtyDir, "dirty-dir", "", "Directory containing queued local path markers")
	commandFlags.StringVar(&suppressDir, "suppress-dir", "", "Directory for remote-originated event suppression markers")
	commandFlags.StringVar(&recoveryDir, "recovery-dir", "", "Directory used to preserve event-deleted local files")
	commandFlags.StringVar(&healthFile, "health-file", "", "JSON health status file")
}

var commandDefinition = &cobra.Command{
	Use:   "protonwatch remote: local-directory",
	Short: "Download Proton Drive changes using the share event stream.",
	RunE: func(command *cobra.Command, args []string) error {
		cmd.CheckArgs(2, 2, command, args)
		if stateFile == "" || lockFile == "" || fallbackMarker == "" ||
			dirtyDir == "" || suppressDir == "" || recoveryDir == "" || healthFile == "" {
			return errors.New("--state-file, --lock-file, --fallback-marker, --dirty-dir, --suppress-dir, --recovery-dir and --health-file are required")
		}
		fsrc, fdst := cmd.NewFsSrcDst(args)
		source, ok := fsrc.(eventSource)
		if !ok {
			return fmt.Errorf("%s does not support Proton event polling", fsrc)
		}
		localRoot, err := filepath.Abs(args[1])
		if err != nil {
			return err
		}
		watcher := &eventWatcher{
			source:         source,
			fsrc:           fsrc,
			fdst:           fdst,
			remoteIdentity: args[0],
			localRoot:      localRoot,
			stateFile:      stateFile,
			lockFile:       lockFile,
			fallbackMarker: fallbackMarker,
			dirtyDir:       dirtyDir,
			suppressDir:    suppressDir,
			recoveryDir:    recoveryDir,
			healthFile:     healthFile,
			pollInterval:   time.Duration(pollInterval),
		}
		return watcher.run(context.Background())
	},
}

// protonEventCallTimeout bounds a single lightweight event-API call
// (fetching the latest event ID, or polling for changes since one). These
// are single HTTP round trips, unlike buildIndex which legitimately walks
// the whole tree and is intentionally left unbounded. Without this bound, a
// stalled or endlessly-retried request can hang the watcher indefinitely
// instead of erroring out and letting the existing degraded/retry and
// in-place-reindex recovery paths do their job.
const protonEventCallTimeout = 2 * time.Minute

type eventWatcher struct {
	source         eventSource
	fsrc           fs.Fs
	fdst           fs.Fs
	remoteIdentity string
	localRoot      string
	stateFile      string
	lockFile       string
	fallbackMarker string
	dirtyDir       string
	suppressDir    string
	recoveryDir    string
	healthFile     string
	pollInterval   time.Duration
	state          watcherState
}

func (w *eventWatcher) requestFallback(err error) error {
	if markerErr := os.MkdirAll(filepath.Dir(w.fallbackMarker), 0o755); markerErr == nil {
		_ = os.WriteFile(w.fallbackMarker, []byte(time.Now().Format(time.RFC3339)+"\n"), 0o600)
	}
	w.writeHealth("fallback", err.Error())
	return err
}

func (w *eventWatcher) writeHealth(status, message string) {
	value := map[string]any{
		"status": status, "message": message, "updated": time.Now().Format(time.RFC3339),
		"event_id": w.state.EventID, "indexed": len(w.state.Items),
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(w.healthFile), 0o755); err != nil {
		return
	}
	temporary := w.healthFile + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err == nil {
		_ = os.Rename(temporary, w.healthFile)
	}
}

func (w *eventWatcher) loadState() error {
	data, err := os.ReadFile(w.stateFile)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &w.state); err != nil {
		return err
	}
	if w.state.Remote != w.remoteIdentity {
		return fmt.Errorf("state belongs to %q, not %q", w.state.Remote, w.remoteIdentity)
	}
	if w.state.Items == nil {
		w.state.Items = make(map[string]indexedItem)
	}
	return nil
}

func (w *eventWatcher) saveState() error {
	if err := os.MkdirAll(filepath.Dir(w.stateFile), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(&w.state, "", "  ")
	if err != nil {
		return err
	}
	tempFile := w.stateFile + ".tmp"
	if err := os.WriteFile(tempFile, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tempFile, w.stateFile)
}

func markerName(remote string) string {
	return fmt.Sprintf("%x.json", sha256.Sum256([]byte(remote)))
}

func pathsOverlap(left, right string) bool {
	left = strings.Trim(strings.TrimSpace(left), "/")
	right = strings.Trim(strings.TrimSpace(right), "/")
	return left == right || (left != "" && strings.HasPrefix(right, left+"/")) || (right != "" && strings.HasPrefix(left, right+"/"))
}

func (w *eventWatcher) conflictsWithDirty(remote string) (bool, error) {
	entries, err := os.ReadDir(w.dirtyDir)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(w.dirtyDir, entry.Name()))
		if err != nil {
			return false, err
		}
		var marker struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(data, &marker); err != nil {
			return false, err
		}
		if pathsOverlap(marker.Path, remote) {
			return true, nil
		}
	}
	return false, nil
}

func (w *eventWatcher) suppress(remote, operation string) error {
	if err := os.MkdirAll(w.suppressDir, 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(map[string]string{"path": remote, "operation": operation})
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(w.suppressDir, markerName(remote)), data, 0o600)
}

func entryID(entry fs.DirEntry) string {
	if ider, ok := entry.(fs.IDer); ok {
		return ider.ID()
	}
	return ""
}

func (w *eventWatcher) buildIndex(ctx context.Context) error {
	w.state.Items = make(map[string]indexedItem)
	return walk.ListR(ctx, w.fsrc, "", true, -1, walk.ListAll, func(entries fs.DirEntries) error {
		for _, entry := range entries {
			id := entryID(entry)
			if id == "" {
				continue
			}
			_, isDir := entry.(fs.Directory)
			w.state.Items[id] = indexedItem{
				Path:  path.Clean(entry.Remote()),
				IsDir: isDir,
			}
		}
		return nil
	})
}

// reindex rebuilds the link index and re-anchors the event cursor at the
// current latest event. It is used both for the first run and to self-heal an
// expired Proton event stream ("refresh") in place, without a full bisync.
func (w *eventWatcher) reindex(ctx context.Context) error {
	latestCtx, latestCancel := context.WithTimeout(ctx, protonEventCallTimeout)
	eventID, err := w.source.LatestEventID(latestCtx)
	latestCancel()
	if err != nil {
		return fmt.Errorf("get latest Proton event ID: %w", err)
	}
	fs.Logf(w.fsrc, "Building Proton event link index")
	if err := w.buildIndex(ctx); err != nil {
		return fmt.Errorf("build Proton event link index: %w", err)
	}
	w.state.Remote = w.remoteIdentity
	w.state.EventID = eventID
	if err := w.saveState(); err != nil {
		return fmt.Errorf("save Proton event state: %w", err)
	}
	fs.Logf(w.fsrc, "Proton event index ready with %d items", len(w.state.Items))
	return nil
}

func (w *eventWatcher) initialize(ctx context.Context) error {
	if err := w.loadState(); err != nil {
		return w.requestFallback(fmt.Errorf("load Proton event state: %w", err))
	}
	if w.state.EventID != "" {
		return nil
	}
	if err := w.reindex(ctx); err != nil {
		return w.requestFallback(err)
	}
	return nil
}

func safeRelative(remote string) (string, error) {
	cleaned := path.Clean(strings.Trim(remote, "/"))
	if cleaned == "." {
		return "", nil
	}
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fmt.Errorf("unsafe event path %q", remote)
	}
	return cleaned, nil
}

func (w *eventWatcher) localPath(remote string) (string, error) {
	relative, err := safeRelative(remote)
	if err != nil {
		return "", err
	}
	return filepath.Join(w.localRoot, filepath.FromSlash(relative)), nil
}

func (w *eventWatcher) rewriteDescendants(oldPath, newPath string) {
	oldPrefix := strings.TrimSuffix(oldPath, "/") + "/"
	for id, item := range w.state.Items {
		if strings.HasPrefix(item.Path, oldPrefix) {
			item.Path = newPath + strings.TrimPrefix(item.Path, oldPath)
			w.state.Items[id] = item
		}
	}
}

func (w *eventWatcher) removeLocal(item indexedItem) error {
	localPath, err := w.localPath(item.Path)
	if err != nil {
		return err
	}
	if item.Path == "" {
		return errors.New("refusing to remove local sync root")
	}
	recoveryPath := filepath.Join(w.recoveryDir, time.Now().Format("20060102-150405.000000000"), filepath.FromSlash(item.Path))
	if err := os.MkdirAll(filepath.Dir(recoveryPath), 0o755); err != nil {
		return err
	}
	err = os.Rename(localPath, recoveryPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (w *eventWatcher) moveLocal(oldItem indexedItem, newPath string) error {
	oldLocal, err := w.localPath(oldItem.Path)
	if err != nil {
		return err
	}
	newLocal, err := w.localPath(newPath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(newLocal), 0o755); err != nil {
		return err
	}
	err = os.Rename(oldLocal, newLocal)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (w *eventWatcher) applyChange(ctx context.Context, change protondrive.EventChange) error {
	oldItem, existed := w.state.Items[change.LinkID]
	conflictPath := change.Path
	if conflictPath == "" && existed {
		conflictPath = oldItem.Path
	}
	dirty, err := w.conflictsWithDirty(conflictPath)
	if err != nil {
		return err
	}
	if dirty {
		return fmt.Errorf("remote event conflicts with queued local change: %s", conflictPath)
	}
	if change.IsDeleted {
		if !existed {
			// The item was never indexed locally (created and deleted
			// remotely between polls, or filtered out). There is nothing to
			// remove, so treat the delete as a no-op rather than wedging the
			// whole event stream.
			fs.Logf(w.fsrc, "Ignoring delete for unindexed Proton link %s", change.LinkID)
			return nil
		}
		localPath, err := w.localPath(oldItem.Path)
		if err != nil {
			return err
		}
		if _, err := os.Lstat(localPath); err == nil {
			if err := w.suppress(oldItem.Path, "delete"); err != nil {
				return err
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err := w.removeLocal(oldItem); err != nil {
			return err
		}
		delete(w.state.Items, change.LinkID)
		if oldItem.IsDir {
			oldPrefix := strings.TrimSuffix(oldItem.Path, "/") + "/"
			for id, item := range w.state.Items {
				if strings.HasPrefix(item.Path, oldPrefix) {
					delete(w.state.Items, id)
				}
			}
		}
		fs.Logf(w.fsrc, "Deleted local path from Proton event: %s", oldItem.Path)
		return nil
	}

	newPath, err := safeRelative(change.Path)
	if err != nil {
		return err
	}
	if existed && oldItem.Path != newPath {
		if err := w.suppress(newPath, "upload"); err != nil {
			return err
		}
		if err := w.moveLocal(oldItem, newPath); err != nil {
			return err
		}
		if oldItem.IsDir {
			w.rewriteDescendants(oldItem.Path, newPath)
		}
	}

	localPath, err := w.localPath(newPath)
	if err != nil {
		return err
	}
	if change.IsDir {
		if err := w.suppress(newPath, "upload"); err != nil {
			return err
		}
		if err := os.MkdirAll(localPath, 0o755); err != nil {
			return err
		}
	} else {
		if err := w.suppress(newPath, "upload"); err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
			return err
		}
		if err := operations.CopyFile(ctx, w.fdst, w.fsrc, newPath, newPath); err != nil {
			return err
		}
	}
	w.state.Items[change.LinkID] = indexedItem{Path: newPath, IsDir: change.IsDir}
	fs.Logf(w.fsrc, "Applied Proton event locally: %s", newPath)
	return nil
}

func (w *eventWatcher) withLock(fn func() error) error {
	if err := os.MkdirAll(filepath.Dir(w.lockFile), 0o755); err != nil {
		return err
	}
	lock, err := os.OpenFile(w.lockFile, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return fn()
}

func (w *eventWatcher) poll(ctx context.Context) error {
	pollCtx, pollCancel := context.WithTimeout(ctx, protonEventCallTimeout)
	batch, err := w.source.PollEvents(pollCtx, w.state.EventID)
	pollCancel()
	if err != nil {
		// A failed poll (network blip, transient API error) is recoverable:
		// log it and retry on the next tick instead of exiting the process or
		// forcing a full bisync.
		fs.Logf(w.fsrc, "Proton event poll failed; will retry: %v", err)
		w.writeHealth("degraded", fmt.Sprintf("event poll failed; retrying: %v", err))
		return nil
	}
	if batch.Refresh || batch.EventID == "" {
		// Proton's event cursor expired. Rebuild the index and re-anchor at
		// the latest event in place, rather than triggering a full bisync.
		fs.Logf(w.fsrc, "Proton event stream expired; rebuilding index in place")
		if err := w.withLock(func() error { return w.reindex(ctx) }); err != nil {
			return w.requestFallback(fmt.Errorf("rebuild after Proton event refresh: %w", err))
		}
		w.writeHealth("ok", "rebuilt index after Proton event refresh")
		return nil
	}
	if len(batch.Changes) == 0 {
		w.state.EventID = batch.EventID
		if err := w.saveState(); err != nil {
			return err
		}
		w.writeHealth("ok", "event poll completed")
		return nil
	}

	var skipped int
	err = w.withLock(func() error {
		for _, change := range batch.Changes {
			if applyErr := w.applyChange(ctx, change); applyErr != nil {
				// A single unapplicable event (e.g. a file whose signature the
				// library cannot verify, or one that conflicts with a pending
				// local change) must never wedge the whole stream. Skip it,
				// keep processing the rest, and still advance the cursor so the
				// watcher makes forward progress.
				skipped++
				fs.Logf(w.fsrc, "Skipping Proton event for link %s: %v", change.LinkID, applyErr)
			}
		}
		w.state.EventID = batch.EventID
		return w.saveState()
	})
	if err != nil {
		// Only an inability to persist progress reaches here.
		return w.requestFallback(fmt.Errorf("save Proton event state: %w", err))
	}
	applied := len(batch.Changes) - skipped
	if skipped > 0 {
		w.writeHealth("degraded", fmt.Sprintf("applied %d event(s), skipped %d unapplicable", applied, skipped))
	} else {
		w.writeHealth("ok", fmt.Sprintf("applied %d event(s)", applied))
	}
	return nil
}

func (w *eventWatcher) run(ctx context.Context) error {
	if err := w.initialize(ctx); err != nil {
		return err
	}
	ticker := time.NewTicker(w.pollInterval)
	defer ticker.Stop()
	for {
		if err := w.poll(ctx); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
