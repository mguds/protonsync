# rclone-build

Reproducibly builds the custom rclone binary (`protonsync-rclone`) used by
protonsync. The binary adds two things to upstream rclone:

- **Proton Drive "Shared with me" support** as a remote root
  (`protondrive,shared_with_me=true:NAME`), and
- a new **`protonwatch`** command that streams Proton Drive change events and
  downloads only what changed.

## Build

```bash
./build.sh
```

This:

1. clones three upstream rclone-org repositories at the exact commits in
   [`pinned-commits.txt`](pinned-commits.txt),
2. applies the patches under [`patches/`](patches/), and
3. compiles `protonsync-rclone` in this directory.

Requirements: `git` and **Go ≥ 1.25** (upstream rclone's `go.mod` requires it).
Network access is needed for the clones and Go module downloads.

## What the patches contain

| Repository | Changes |
|---|---|
| `rclone` | `shared_with_me` option on the protondrive backend; new `cmd/protonwatch`; `events.go`; registration in `cmd/all`; local `replace` directives in `go.mod` |
| `proton-api-bridge` | event support (`events.go`) and supporting changes; local `replace` for go-proton-api |
| `go-proton-api` | share/link type and event-related changes |

Each fork's tracked changes are in `patches/<fork>/tracked.patch`; new files are
under `patches/<fork>/new/` and copied into the upstream tree by `build.sh`.

The three upstream projects are MIT licensed; these patches are released under
MIT as well. See [`../NOTICE`](../NOTICE).

## Verifying a release binary

The `protonsync-rclone` binary attached to a GitHub Release is built from exactly
these commits and patches. You can rebuild and compare, or simply check it
exposes the custom command:

```bash
./protonsync-rclone version
./protonsync-rclone protonwatch --help
```
