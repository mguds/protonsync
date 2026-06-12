# Concurrent editing and conflicts

protonsync keeps a local folder and a Proton Drive shared folder in sync. It is
**not** a real-time co-editing or document-management system. Read this before
several people use the same shared folder.

## What is safe

- **Different files, different people, same time.** Fully supported. Each saved
  file propagates to the other machines within seconds.
- **Sequential editing of the same file.** Person A edits and saves, the change
  reaches Person B, then Person B edits. Fine.

## What is NOT safe

- **Two people editing the same file at the same time.** There is no distributed
  lock and no automatic merge. This applies especially to binary formats that
  cannot be merged: Word, Excel, PowerPoint, CAD, images, PDFs, archives, etc.

If two machines change the same file before they have received each other's
version, one of these happens:

- a **conflict copy** is created (the losing side is renamed with a
  `protonsync-conflict` suffix and a number), or
- one revision simply wins and the other becomes an older Proton revision.

No data is silently destroyed — but you may have to reconcile two versions by
hand.

## How protonsync reduces the risk

- A shared file lock serializes all sync operations **on one machine** (it does
  **not** span machines).
- `bisync` conflict handling keeps **both** sides on conflict
  (`--conflict-resolve none`, losing side renamed) instead of overwriting.
- Files deleted via a remote event are first moved to
  `~/.local/state/protonsync-recovery/` before being deleted locally.
- Proton Drive's own version history remains available as a final safety net.

These reduce risk; they do not guarantee a clean outcome for genuinely
simultaneous edits.

## Recommended practice

1. Agree on **who** edits a given file, or
2. Use short-lived "I'm editing X" coordination (chat/checkout convention), and
3. For documents that truly need simultaneous editing, use a system designed for
   it (a real co-editing suite or a PDM/document-management system with
   check-in/check-out).
