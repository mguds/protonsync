package protonwatch

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/rclone/rclone/backend/protondrive"
	"github.com/stretchr/testify/require"
)

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
