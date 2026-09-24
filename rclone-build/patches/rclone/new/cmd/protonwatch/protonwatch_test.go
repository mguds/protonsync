package protonwatch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/rclone/rclone/backend/protondrive"
	"github.com/stretchr/testify/require"
)

// fakeEventSource lets tests control PollEvents/LatestEventID without a real
// Proton connection.
type fakeEventSource struct {
	batches      []*protondrive.EventBatch
	polledIDs    []string
	pollErr      error
	latestID     string
	latestErr    error
	latestCalled int
}

func (f *fakeEventSource) LatestEventID(context.Context) (string, error) {
	f.latestCalled++
	return f.latestID, f.latestErr
}

func (f *fakeEventSource) PollEvents(_ context.Context, eventID string) (*protondrive.EventBatch, error) {
	f.polledIDs = append(f.polledIDs, eventID)
	if f.pollErr != nil || len(f.batches) == 0 {
		return nil, f.pollErr
	}
	batch := f.batches[0]
	f.batches = f.batches[1:]
	return batch, nil
}

func TestSafeRelative(t *testing.T) {
	for _, test := range []struct {
		input string
		want  string
		ok    bool
	}{
		{input: "folder/file.txt", want: "folder/file.txt", ok: true},
		{input: "/folder/file.txt", want: "folder/file.txt", ok: true},
		{input: ".", want: "", ok: true},
		{input: "../outside", ok: false},
		{input: "folder/../../outside", ok: false},
	} {
		got, err := safeRelative(test.input)
		if test.ok {
			require.NoError(t, err)
			require.Equal(t, test.want, got)
		} else {
			require.Error(t, err)
		}
	}
}

func TestRewriteDescendants(t *testing.T) {
	watcher := eventWatcher{
		state: watcherState{
			Items: map[string]indexedItem{
				"folder": {Path: "old", IsDir: true},
				"file":   {Path: "old/child/file.txt"},
				"other":  {Path: "other/file.txt"},
			},
		},
	}
	watcher.rewriteDescendants("old", "new")
	require.Equal(t, "new/child/file.txt", watcher.state.Items["file"].Path)
	require.Equal(t, "other/file.txt", watcher.state.Items["other"].Path)
}

func TestRemoveLocalRefusesRoot(t *testing.T) {
	watcher := eventWatcher{localRoot: t.TempDir()}
	err := watcher.removeLocal(indexedItem{Path: "", IsDir: true})
	require.Error(t, err)
}

func TestRemoveLocalDirectory(t *testing.T) {
	root := t.TempDir()
	recovery := t.TempDir()
	child := filepath.Join(root, "folder", "file.txt")
	require.NoError(t, os.MkdirAll(filepath.Dir(child), 0o755))
	require.NoError(t, os.WriteFile(child, []byte("test"), 0o600))

	watcher := eventWatcher{localRoot: root, recoveryDir: recovery}
	require.NoError(t, watcher.removeLocal(indexedItem{Path: "folder", IsDir: true}))
	_, err := os.Stat(filepath.Join(root, "folder"))
	require.ErrorIs(t, err, os.ErrNotExist)
	matches, err := filepath.Glob(filepath.Join(recovery, "*", "folder", "file.txt"))
	require.NoError(t, err)
	require.Len(t, matches, 1)
}

func TestApplyChangeIgnoresUnknownDelete(t *testing.T) {
	watcher := eventWatcher{
		dirtyDir: t.TempDir(),
		state:    watcherState{Items: map[string]indexedItem{}},
	}
	// A delete event for a link we never indexed must be a no-op, not a fatal
	// error that wedges the whole event stream.
	err := watcher.applyChange(context.Background(), protondrive.EventChange{
		LinkID:    "missing",
		IsDeleted: true,
	})
	require.NoError(t, err)
}

func TestPathsOverlap(t *testing.T) {
	require.True(t, pathsOverlap("folder", "folder/file.txt"))
	require.True(t, pathsOverlap("folder/file.txt", "folder"))
	require.True(t, pathsOverlap("folder/file.txt", "folder/file.txt"))
	require.False(t, pathsOverlap("folder-a", "folder-b/file.txt"))
}

func newTestWatcher(t *testing.T, source eventSource) *eventWatcher {
	t.Helper()
	dir := t.TempDir()
	return &eventWatcher{
		source:     source,
		stateFile:  filepath.Join(dir, "state.json"),
		lockFile:   filepath.Join(dir, "lock"),
		dirtyDir:   filepath.Join(dir, "dirty"),
		healthFile: filepath.Join(dir, "health.json"),
	}
}

// A poll that keeps failing but hasn't been failing for long must not attempt
// a re-anchor yet - a brief blip should just retry on the next tick.
func TestPollDoesNotReanchorBeforeThreshold(t *testing.T) {
	source := &fakeEventSource{pollErr: errors.New("context deadline exceeded")}
	watcher := newTestWatcher(t, source)
	watcher.firstPollFailure = time.Now().Add(-1 * time.Minute)

	require.NoError(t, watcher.poll(context.Background()))
	require.Equal(t, 0, source.latestCalled, "should not attempt a re-anchor before pollFailureReanchorAfter has elapsed")
	require.False(t, watcher.firstPollFailure.IsZero())
}

// Once a poll has been failing for longer than pollFailureReanchorAfter,
// protonwatch must attempt to re-anchor (the same self-heal used for a
// server-sent Refresh) rather than retrying the same stuck cursor forever.
func TestPollReanchorsAfterSustainedFailure(t *testing.T) {
	source := &fakeEventSource{
		pollErr:   errors.New("context deadline exceeded"),
		latestErr: errors.New("also unreachable"),
	}
	watcher := newTestWatcher(t, source)
	watcher.firstPollFailure = time.Now().Add(-20 * time.Minute)

	require.NoError(t, watcher.poll(context.Background()))
	require.Equal(t, 1, source.latestCalled, "should attempt a re-anchor once the failure has been sustained")
	require.False(t, watcher.firstPollFailure.IsZero(), "failure is still ongoing since the re-anchor attempt itself failed")
	require.False(t, watcher.lastReanchorAttempt.IsZero())
}

// A re-anchor attempt must not be retried on every single poll while the
// outage continues - only after reanchorRetryBackoff has passed again.
func TestPollReanchorRespectsBackoff(t *testing.T) {
	source := &fakeEventSource{
		pollErr:   errors.New("context deadline exceeded"),
		latestErr: errors.New("also unreachable"),
	}
	watcher := newTestWatcher(t, source)
	watcher.firstPollFailure = time.Now().Add(-20 * time.Minute)
	watcher.lastReanchorAttempt = time.Now().Add(-1 * time.Minute)

	require.NoError(t, watcher.poll(context.Background()))
	require.Equal(t, 0, source.latestCalled, "a recent re-anchor attempt should block another one until the backoff elapses")
}

func TestConflictsWithDirty(t *testing.T) {
	dirty := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dirty, "marker.json"), []byte(`{"path":"folder/file.txt"}`), 0o600))
	watcher := eventWatcher{dirtyDir: dirty}
	conflict, err := watcher.conflictsWithDirty("folder")
	require.NoError(t, err)
	require.True(t, conflict)
	conflict, err = watcher.conflictsWithDirty("other")
	require.NoError(t, err)
	require.False(t, conflict)
}

// A multi-page backlog must be consumed page by page: each page's cursor is
// persisted and used for the next request, and More makes run() poll again
// without waiting.
func TestPollAdvancesCursorPageByPage(t *testing.T) {
	source := &fakeEventSource{batches: []*protondrive.EventBatch{
		{EventID: "page1", More: true},
		{EventID: "page2", More: true},
		{EventID: "page3", More: false},
	}}
	watcher := newTestWatcher(t, source)
	watcher.state.EventID = "start"

	for _, want := range []struct {
		id   string
		more bool
	}{{"page1", true}, {"page2", true}, {"page3", false}} {
		require.NoError(t, watcher.poll(context.Background()))
		require.Equal(t, want.id, watcher.state.EventID)
		require.Equal(t, want.more, watcher.morePending)
	}
	require.Equal(t, []string{"start", "page1", "page2"}, source.polledIDs)
}

// A dead session exits (without the fallback marker, so state and index are
// kept) to re-login - but never within authFailureExitAfter of starting.
func TestPollExitsOnAuthFailureAfterGracePeriod(t *testing.T) {
	authErr := errors.New("failed to refresh auth: failed to refresh auth, de-auth: 400 POST /auth/v4/refresh: Invalid refresh token")
	source := &fakeEventSource{pollErr: authErr}

	fresh := newTestWatcher(t, source)
	fresh.started = time.Now()
	require.NoError(t, fresh.poll(context.Background()))

	old := newTestWatcher(t, source)
	old.started = time.Now().Add(-20 * time.Minute)
	require.Error(t, old.poll(context.Background()))
	_, err := os.Stat(old.fallbackMarker)
	require.True(t, old.fallbackMarker == "" || errors.Is(err, os.ErrNotExist), "auth exit must not request a fallback re-index")

	require.False(t, isAuthFailure(errors.New("context deadline exceeded")))
}
