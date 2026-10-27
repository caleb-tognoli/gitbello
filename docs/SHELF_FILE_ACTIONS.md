# Per-file shelf actions

Status: core/Godot interface additions approved by Caleb on 2026-10-27; implemented with regression coverage.

## User-visible behavior

- Right-clicking a file in the Shelves file list selects that file and offers **Restore file** and **Discard file** through the action registry.
- Restore applies only that file's shelved changes to the current worktree, preserving its staged changes when they apply. After success, the file leaves the shelf. Other shelved files and unrelated working-copy changes remain intact. A rename includes its original path.
- A failed or conflicting restore keeps the original shelf available. Existing local edits must never be silently overwritten.
- Discard asks for confirmation, removes only that file from the shelf, and offers Undo through the existing shelf-discard action. Undo replaces the remaining shelf with its original contents rather than adding a duplicate shelf.
- A shelf with no remaining files disappears. Otherwise its name, branch and automatic-shelf metadata remain, and the UI follows the remaining shelf and selects the next available file.
- As with whole-shelf actions, Git work runs on core workers and repository writes are serialized.

## Interface additions

Keep the existing whole-shelf operations unchanged. Add:

- `Runtime::restore_shelf_file(key, oid, path) -> Option<JobId>` and its thin `RepoSession.restore_shelf_file(oid, path) -> job_id` binding.
- `Runtime::discard_shelf_file(key, oid, path) -> Option<JobId>` and its thin `RepoSession.discard_shelf_file(oid, path) -> job_id` binding.
- A core shelf-replacement event and `RepoSession.shelf_replaced(old_oid, new_oid)` signal, where an empty new ID means the shelf was removed. This keeps selection tied to the correct shelf after its immutable Git commit changes, including when Undo replaces it again.

The backend trait gains corresponding per-file operations. All stash inspection, splitting and replacement stays in core; GDScript builds the menu and presents results. No new dependency or Godot addon is needed.

## Core implementation constraints

Build a replacement stash using temporary indexes and Git tree/commit operations through GitRunner, retaining the original base and separating tracked, staged and untracked contents. Never apply the whole shelf to the working copy merely to extract one file. Validate the shelf and file by their current IDs before changing anything.

For Restore, apply a temporary stash containing only the selected file through a separate HEAD index, then copy just the selected paths' index entries (including conflict stages) to the real index. This preserves unrelated staged work. Existing local changes on the selected paths are refused. Replace the original shelf with its remainder after success. For Discard, replace it directly. Retain the original commit for recovery and Undo, and retain a reachable recovery reference if replacement fails. Undo must refuse to replace a remainder that has since changed or disappeared or was renamed. All shelf writes share a common-directory lock across worktrees; a concurrent operation gets a retryable lock error. Index-only remainders stay visible in the file list, and replacement shelves keep their original date.

## Required verification

- Real temporary repositories: restoring and discarding one file from a multi-file shelf; unrelated local edits and shelves unchanged; staged/unstaged content; untracked, added, deleted, renamed and binary files; paths with spaces and non-ASCII characters; missing or stale shelf/file IDs; conflicting restores retaining the original shelf; last-file removal; partial-discard Undo without duplicates; shelf visibility across worktrees.
- UI smoke: right-click target and exact menu entries; file actions through the registry; confirmation and Undo; selection follows the replacement; removing the last file preserves the existing empty-shelf navigation behavior.
- Run `cargo xtask check`, the relevant UI smoke tests, and inspect a windowed file-menu capture before completion.

## Verification result

`cargo xtask check` and all 16 UI smoke scripts pass on Windows. Eleven per-file integration tests cover the cases above, including ignored-file protection and index-only previews; the scheduler also checks that a completed shelf swap still delivers its result after cancellation. Windowed dark/light captures verify the real right-click menu. The shelf smoke exercises pointer targeting, partial discard and Undo, partial restore, selection following the remainder, and both last-file operations. Dismissing notification toasts during the test also exposed and fixed a timer callback retaining a freed toast.

Manual check: open a shelf containing two files, right-click one and choose Restore file; confirm that only that file returns to Changes. Discard the remaining file, then use Undo and confirm the shelf returns once with its remaining file. Existing local edits on a selected path should produce a refusal, preserving both the working file and the shelf.
