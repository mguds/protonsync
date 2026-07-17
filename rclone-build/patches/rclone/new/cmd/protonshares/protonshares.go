// Package protonshares lists Proton Drive "Shared with me" items.
package protonshares

import (
	"context"
	"fmt"

	"github.com/rclone/rclone/backend/protondrive"
	"github.com/rclone/rclone/cmd"
	"github.com/spf13/cobra"
)

func init() {
	cmd.Root.AddCommand(commandDefinition)
}

type sharedLister interface {
	ListSharedWithMeItems(ctx context.Context) ([]protondrive.SharedItem, error)
}

var commandDefinition = &cobra.Command{
	Use:   "protonshares remote:",
	Short: `List Proton Drive "Shared with me" items.`,
	Long: `List every top-level item in Proton Drive "Shared with me" for the
account behind the given remote. The remote must be a plain protondrive
remote (for example "protondrive:"), not one in shared_with_me mode.

Each item is printed on its own line as:

    d<TAB>Name    for folders
    f<TAB>Name    for files

The output is intended to be machine-readable (used by the protonsync
installer to enumerate shares).`,
	RunE: func(command *cobra.Command, args []string) error {
		cmd.CheckArgs(1, 1, command, args)
		fsrc := cmd.NewFsSrc(args)
		lister, ok := fsrc.(sharedLister)
		if !ok {
			return fmt.Errorf("%v does not support listing Proton shared-with-me items", fsrc)
		}
		items, err := lister.ListSharedWithMeItems(context.Background())
		if err != nil {
			return err
		}
		for _, item := range items {
			kind := "f"
			if item.IsFolder {
				kind = "d"
			}
			fmt.Printf("%s\t%s\n", kind, item.Name)
		}
		return nil
	},
}
