class_name Menus
extends RefCounted
## One menu per object: a branch, remote branch, tag, worktree,
## commit, file and diff have one definition, used wherever their menu opens.
## Entries are `ActionMenu.fill` entries; actions that do not apply where the
## menu opens hide themselves (`Action.visible`).
##
## Order: the primary action, then what creates something, then the families
## (Compare ▸, Copy ▸, Open in ▸), then what removes or overwrites, last.
##
## Built when a menu opens, so family labels follow the language.


## The menu of `ref`, by its type ("branch", "remote", "tag", "worktree").
static func ref(type: String) -> Array:
	match type:
		"branch":
			return [&"branch.checkout", &"branch.new_worktree", &"branch.merge", &"", &"branch.new", &"tag.new", &"", compare_ref(),
				&"branch.copy_name", &"branch.open_web", &"", &"branch.rename", &"branch.set_upstream", &"",
				&"branch.delete"]
		"remote":
			return [&"branch.checkout", &"branch.new_worktree", &"branch.merge", &"", &"branch.new", &"tag.new", &"", compare_ref(),
				&"branch.copy_name", &"branch.open_web", &"", &"branch.delete_remote"]
		"tag":
			return [&"commit.checkout", &"branch.merge", &"", &"branch.new", &"", compare_ref(), &"branch.copy_name",
				&"branch.open_web", &"", &"tag.push", &"", &"tag.delete"]
		"worktree":
			return worktree()
	return []


## A worktree's menu: its own items, then Branch ▸ (the menu of the branch
## checked out there, with `branch_scope`: see `ActionMenu.scope`), then Lock
## beside Delete (a lock keeps the worktree from being deleted or pruned).
static func worktree(branch_scope: Callable = Callable()) -> Array:
	var out: Array = [_open(&"worktree.open_terminal", &"worktree.show_in_file_manager"), &"worktree.copy_path", &""]
	if branch_scope.is_valid():
		out.append_array([ActionMenu.scoped(_t("Branch"), ref("branch"), branch_scope, &"GitBranch"), &""])
	out.append_array([&"worktree.lock", &"worktree.unlock", &"worktree.remove"])
	return out


## A commit's menu in History.
static func commit() -> Array:
	return [&"history.compare_selected", &"", &"commit.checkout", &"commit.cherry_pick", &"commit.merge",
		&"commit.amend", &"", &"branch.new", &"tag.new", &"commit.new_worktree", &"", compare_commit(), copy_commit(), &"commit.open_web"]


## A changed file's menu in Changes (`ignore` is the Ignore ▸ submenu, or
## &"" when the files cannot be ignored).
static func changed_file(ignore: Variant) -> Array:
	return [&"diff.open_file", &"changes.show_file", &"file_history.open", &"changes.copy_path", &"",
		&"conflict.file_ours", &"conflict.file_theirs", &"conflict.reopen", &"",
		ignore, &"changes.restore_line_endings", &"", &"changes.shelve", &"changes.discard", &"changes.undo_discard"]


## An ignored file's menu ("Show ignored files"): open it or bring it back.
static func ignored_file() -> Array:
	return [&"diff.open_file", &"changes.show_file", &"changes.copy_path", &"",
		&"changes.stop_ignoring", &"changes.undo_ignore"]


## A file of a commit, a comparison or a shelf, then `extra` (what restores
## or removes it).
static func file_at_commit(extra: Array = []) -> Array:
	var out: Array = [&"diff.open_file", &"file_history.open", &"diff.copy_path", &"diff.open_web", &""]
	out.append_array(extra)
	return out


## A diff's menu: copy, open, view, then `extra` (what changes the file).
static func diff(extra: Array = [], file_history: bool = true) -> Array:
	var out: Array = [&"diff.copy", &"diff.select_all", &"", &"diff.open_file"]
	if file_history:
		out.append(&"file_history.open")
	out.append(&"diff.open_web")
	out.append_array([&"", &"diff.toggle_minimap", &""])
	out.append_array(extra)
	return out


## The resolver's menu on a conflict block.
static func conflict_block() -> Array:
	return [&"conflict.use_ours", &"conflict.use_theirs", &"conflict.use_both", &"conflict.use_both_reversed",
		&"", &"conflict.undo", &"", &"diff.copy", &"diff.select_all", &"", &"diff.open_file", &"file_history.open",
		&"", &"diff.toggle_minimap"]


## A Home row's menu.
static func home_row() -> Array:
	return [&"home.row_open", &"home.row_pin", &"home.row_unpin", &"home.row_rename", &"home.row_relocate", &"",
		_open(&"home.row_terminal", &"home.row_show"), &"home.row_copy_path", &"", &"home.row_remove"]


## Compare ▸ for a branch or tag.
static func compare_ref() -> Dictionary:
	return ActionMenu.family(_t("Compare"), [&"compare.with_current", &"compare.with"], {
		&"compare.with_current": _t("With current branch"), &"compare.with": _t("With…")}, &"GitCompare")


## Compare ▸ for a commit.
static func compare_commit() -> Dictionary:
	return ActionMenu.family(_t("Compare"), [&"commit.compare_working", &"commit.compare_with"], {
		&"commit.compare_working": _t("With working copy"), &"commit.compare_with": _t("With…")}, &"GitCompare")


## Copy ▸ for a commit.
static func copy_commit() -> Dictionary:
	return ActionMenu.family(_t("Copy"), [&"commit.copy_hash", &"commit.copy_short_hash", &"commit.copy_subject",
		&"commit.copy_message"], {&"commit.copy_hash": _t("Hash"), &"commit.copy_short_hash": _t("Short hash"),
		&"commit.copy_subject": _t("Subject"), &"commit.copy_message": _t("Message")}, &"ActionCopy")


## Repository → Open in ▸ in the menu bar.
static func open_repository() -> Dictionary:
	return _open(&"repo.open_terminal", &"repo.show_in_file_manager")


## Worktree → Open in ▸ in the menu bar.
static func open_worktree() -> Dictionary:
	return _open(&"worktree.open_terminal", &"worktree.show_in_file_manager")


static func _open(terminal: StringName, file_manager: StringName) -> Dictionary:
	return ActionMenu.family(_t("Open in"), [terminal, file_manager], {
		terminal: _t("Terminal"), file_manager: _t("File manager")}, &"ExternalLink")


static func _t(text: String) -> String:
	return String(TranslationServer.translate(text))
