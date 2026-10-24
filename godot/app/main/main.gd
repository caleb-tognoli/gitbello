class_name Main
extends PanelContainer
## App shell (PLAN §4): one tab per repository, welcome screen, git command
## log, status bar, toasts and the command palette. Every user operation is an
## action in `Actions`.

const MIN_WINDOW_SIZE: Vector2i = Vector2i(960, 600)
const REPO_ARG: String = "--repo="
const REPO_TAB: PackedScene = preload("res://app/repo_tab/repo_tab.tscn")

var _pages: Array[RepoTab] = []
var _current: int = -1

@onready var _tab_strip: Control = %TabStrip
@onready var _tabs: TabBar = %Tabs
@onready var _add_button: Button = %AddButton
@onready var _content: Control = %Content
@onready var _welcome: Welcome = %Welcome
@onready var _git_log: GitLogPanel = %GitLog
@onready var _status_label: Label = %StatusLabel
@onready var _version_label: Label = %VersionLabel
@onready var _toasts: Toasts = %Toasts
@onready var _jobs_bar: JobsBar = %JobsBar
@onready var _palette: CommandPalette = %Palette
@onready var _shortcuts_dialog: ShortcutsDialog = %ShortcutsDialog


func _ready() -> void:
	var window: Window = get_window()
	window.min_size = MIN_WINDOW_SIZE
	window.content_scale_factor = ThemeManager.ui_scale(window)
	ThemeManager.apply(self)
	if DisplayServer.has_method(&"set_system_theme_change_callback"):
		DisplayServer.set_system_theme_change_callback(_on_system_theme_changed)
	window.files_dropped.connect(_on_files_dropped)

	_version_label.text = "gitbello %s · git %s" % [Core.core_version(), Core.git_version()]
	_git_log.custom_minimum_size.y = float(get_theme_constant(&"height", &"GitLogPanel"))
	_toasts.custom_minimum_size.x = float(get_theme_constant(&"width", &"Toasts"))
	_tabs.max_tab_width = get_theme_constant(&"max_tab_width", &"Shell")
	_palette.dynamic_entries = _palette_entries
	_toasts.fix_provider = _error_fixes
	_toasts.error_filter = _error_handled_elsewhere

	_tabs.tab_changed.connect(_on_tab_changed)
	_tabs.tab_close_pressed.connect(close_tab)
	_tabs.active_tab_rearranged.connect(_on_tab_rearranged)
	_add_button.pressed.connect(func() -> void: Actions.run_action(&"repo.open"))
	_welcome.open_requested.connect(func() -> void: Actions.run_action(&"repo.open"))
	_welcome.recent_chosen.connect(open_repo)
	_register_actions()

	if not Core.start_error().is_empty():
		_toasts.show_toast("gitbello cannot run git", Core.start_error())
	if not Core.config_warning().is_empty():
		_toasts.show_toast("Settings file ignored", Core.config_warning())
	_restore_tabs()
	var repo: String = repo_from_args(OS.get_cmdline_user_args())
	if not repo.is_empty():
		open_repo(repo)
	_update_view()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		var active: RepoTab = current_page()
		if active != null and active.session != null:
			Core.focus_in(active.session)
		if Core.theme_choice() == "system":
			ThemeManager.apply(self)


static func repo_from_args(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(REPO_ARG):
			return arg.trim_prefix(REPO_ARG)
	return ""


# --- Tabs -------------------------------------------------------------------

## Opens `path` in a new tab, or focuses its tab if already open.
func open_repo(path: String) -> RepoTab:
	var session: RepoSession = Core.open_session(path)
	if session == null:
		_toasts.show_toast("Cannot open repository", Core.start_error())
		return null
	for i: int in _pages.size():
		if _pages[i].session == session:
			_tabs.current_tab = i
			return _pages[i]
	var page: RepoTab = REPO_TAB.instantiate() as RepoTab
	_content.add_child(page)
	page.setup(session)
	page.title_changed.connect(_on_page_title_changed.bind(page))
	page.notice.connect(func(title: String, message: String) -> void: _toasts.show_toast(title, message))
	_jobs_bar.watch(session)
	_pages.append(page)
	_tabs.add_tab(page.title())
	_tabs.set_tab_metadata(_tabs.tab_count - 1, page)
	_tabs.current_tab = _pages.size() - 1
	_on_page_title_changed(page)
	_update_view()
	_save_tabs()
	_welcome.refresh()
	return page


func close_tab(index: int) -> void:
	if index < 0 or index >= _pages.size():
		return
	var page: RepoTab = _pages[index]
	_pages.remove_at(index)
	Core.close_session(page.session)
	page.queue_free()
	_tabs.remove_tab(index)
	_current = _tabs.current_tab if not _pages.is_empty() else -1
	_update_view()
	_save_tabs()
	_welcome.refresh()


func tab_count() -> int:
	return _pages.size()


func page_at(index: int) -> RepoTab:
	return _pages[index]


func current_page() -> RepoTab:
	return _pages[_tabs.current_tab] if _tabs.current_tab >= 0 and _tabs.current_tab < _pages.size() else null


func tab_bar() -> TabBar:
	return _tabs


func git_log() -> GitLogPanel:
	return _git_log


func toasts() -> Toasts:
	return _toasts


func palette() -> CommandPalette:
	return _palette


func jobs_bar() -> JobsBar:
	return _jobs_bar


## The tab of repository `repo_path` (a session key), or null.
func page_for(repo_path: String) -> RepoTab:
	for p: RepoTab in _pages:
		if p.repo_path() == repo_path:
			return p
	return null


func _restore_tabs() -> void:
	var saved: PackedStringArray = Core.saved_tabs()
	var active: int = Core.saved_active_tab()
	for path: String in saved:
		if DirAccess.dir_exists_absolute(path):
			open_repo(path)
	if active >= 0 and active < _pages.size():
		_tabs.current_tab = active


func _save_tabs() -> void:
	var paths: PackedStringArray = PackedStringArray()
	for p: RepoTab in _pages:
		if not p.has_error():
			paths.append(p.repo_path())
	var error: String = Core.save_tabs(paths, _tabs.current_tab)
	if not error.is_empty():
		_toasts.show_toast("Cannot save settings", error)


func _update_view() -> void:
	_welcome.visible = _pages.is_empty()
	_tab_strip.visible = not _pages.is_empty()
	for i: int in _pages.size():
		_pages[i].visible = i == _tabs.current_tab
	var active: RepoTab = current_page()
	_status_label.text = active.session.toplevel() if active != null else "No repository open"


func _on_tab_changed(index: int) -> void:
	_current = index
	_update_view()
	_save_tabs()
	var active: RepoTab = current_page()
	if active != null:
		active.focus_view()


## TabBar reordered its tabs; rebuild the page list from the tab metadata.
func _on_tab_rearranged(_to: int) -> void:
	_pages.clear()
	for i: int in _tabs.tab_count:
		_pages.append(_tabs.get_tab_metadata(i) as RepoTab)
	_current = _tabs.current_tab
	_update_view()
	_save_tabs()


func _on_page_title_changed(page: RepoTab) -> void:
	var index: int = _pages.find(page)
	if index < 0:
		return
	var badge: String = page.badge_text()
	_tabs.set_tab_title(index, page.title() if badge.is_empty() else "%s   %s" % [page.title(), badge])
	_tabs.set_tab_tooltip(index, page.session.toplevel())
	if index == _tabs.current_tab:
		_status_label.text = page.session.toplevel()


func _on_files_dropped(files: PackedStringArray) -> void:
	for file: String in files:
		open_repo(file if DirAccess.dir_exists_absolute(file) else file.get_base_dir())


# --- Actions ----------------------------------------------------------------

func _register_actions() -> void:
	var has_tab: Callable = func() -> bool: return not _pages.is_empty()
	var many_tabs: Callable = func() -> bool: return _pages.size() > 1
	Actions.register(&"app.command_palette", "Command palette", "App",
			_palette.open, PackedStringArray(["Ctrl+K", "Ctrl+Shift+P"]))
	Actions.register(&"app.keyboard_shortcuts", "Keyboard shortcuts…", "App",
			_shortcuts_dialog.open, PackedStringArray(["Ctrl+Comma"]))
	Actions.register(&"repo.open", "Open repository…", "Repository",
			_show_open_dialog, PackedStringArray(["Ctrl+O"]))
	Actions.register(&"repo.refresh", "Refresh", "Repository",
			func() -> void: current_page().session.refresh(), PackedStringArray(["F5"]), has_tab)
	Actions.register(&"tab.close", "Close tab", "Tabs",
			func() -> void: close_tab(_tabs.current_tab), PackedStringArray(["Ctrl+W"]), has_tab)
	Actions.register(&"tab.next", "Next tab", "Tabs",
			func() -> void: _tabs.current_tab = (_tabs.current_tab + 1) % _pages.size(),
			PackedStringArray(["Ctrl+Tab"]), many_tabs)
	Actions.register(&"tab.previous", "Previous tab", "Tabs",
			func() -> void: _tabs.current_tab = (_tabs.current_tab - 1 + _pages.size()) % _pages.size(),
			PackedStringArray(["Ctrl+Shift+Tab"]), many_tabs)
	Actions.register(&"view.toggle_sidebar", "Toggle sidebar", "View",
			_toggle_sidebars, PackedStringArray(["Ctrl+B"]), has_tab)
	Actions.register(&"view.toggle_git_log", "Toggle git command log", "View",
			func() -> void: _git_log.visible = not _git_log.visible,
			PackedStringArray(["Ctrl+Shift+L"]))
	Actions.register(&"view.history", "Show history", "View",
			func() -> void: current_page().show_view(RepoTab.View.HISTORY),
			PackedStringArray(["Ctrl+1"]), has_tab)
	Actions.register(&"view.changes", "Show changes", "View",
			func() -> void: current_page().show_view(RepoTab.View.CHANGES),
			PackedStringArray(["Ctrl+2"]), has_tab)
	_register_change_actions()
	_register_sync_actions()
	_register_branch_actions()
	Actions.register(&"diff.toggle_side_by_side", "Toggle side-by-side diff", "View",
			_toggle_side_by_side, PackedStringArray(["Ctrl+Shift+D"]))
	for choice: String in ["system", "light", "dark"]:
		Actions.register(StringName("view.theme_" + choice), "Theme: %s" % choice.capitalize(), "View",
				_set_theme.bind(choice))


## Changes-panel actions; they run on the current tab's changes view.
func _register_change_actions() -> void:
	var repo_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session.is_ready()
	var in_changes: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session.is_ready() and page.view == RepoTab.View.CHANGES
	var changes: Callable = func() -> ChangesView: return current_page().changes()
	Actions.register(&"changes.stage_selected", "Stage or unstage the selection", "Changes",
			func() -> void: changes.call().stage_selected(), PackedStringArray(), in_changes)
	Actions.register(&"changes.stage_all", "Stage all changes", "Changes",
			func() -> void: changes.call().stage_all(), PackedStringArray(["Ctrl+Shift+S"]), repo_ready)
	Actions.register(&"changes.unstage_all", "Unstage all changes", "Changes",
			func() -> void: changes.call().unstage_all(), PackedStringArray(["Ctrl+Shift+U"]), repo_ready)
	Actions.register(&"changes.focus_message", "Write commit message", "Changes",
			func() -> void:
				current_page().show_view(RepoTab.View.CHANGES)
				changes.call().focus_message(),
			PackedStringArray(["Ctrl+Shift+M"]), repo_ready)
	Actions.register(&"changes.discard", "Discard selected changes…", "Changes",
			func() -> void: changes.call().discard_selection(), PackedStringArray(["Delete"]), in_changes)
	Actions.register(&"changes.undo_discard", "Undo last discard", "Changes",
			func() -> void: changes.call().undo_discard(), PackedStringArray(["Ctrl+Z"]),
			func() -> bool: return in_changes.call() and current_page().changes().can_undo_discard())
	var amend: ActionRegistry.Action = Actions.register(&"changes.toggle_amend", "Toggle amend last commit", "Changes",
			func() -> void: changes.call().toggle_amend(), PackedStringArray(["Ctrl+Shift+A"]), in_changes)
	amend.in_text_fields = true
	var commit: ActionRegistry.Action = Actions.register(&"changes.commit", "Commit", "Changes",
			func() -> void: changes.call().commit(), PackedStringArray(["Ctrl+Enter"]),
			func() -> bool: return in_changes.call() and current_page().changes().commit_box().can_commit())
	commit.in_text_fields = true


## Fetch, pull, push and friends; they run on the current tab.
func _register_sync_actions() -> void:
	var is_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session.is_ready()
	var session: Callable = func() -> RepoSession: return current_page().session
	var ops: Callable = func() -> RepoOps: return current_page().ops()
	var can_pull: Callable = func() -> bool: return is_ready.call() and session.call().can_pull()
	var can_push: Callable = func() -> bool: return is_ready.call() and session.call().can_push()
	Actions.register(&"sync.fetch", "Fetch", "Sync",
			func() -> void: ops.call().fetch(), PackedStringArray(["Ctrl+Shift+F"]),
			func() -> bool: return is_ready.call() and session.call().can_fetch())
	Actions.register(&"sync.pull", "Pull", "Sync",
			func() -> void: ops.call().pull(), PackedStringArray(["Ctrl+L"]), can_pull)
	for mode: String in ["ff-only", "merge", "rebase"]:
		var label: String = {"ff-only": "Pull (fast-forward only)", "merge": "Pull (merge)", "rebase": "Pull (rebase)"}[mode]
		Actions.register(StringName("sync.pull_" + mode.replace("-", "_")), label, "Sync",
				func() -> void: ops.call().pull(mode), PackedStringArray(), can_pull)
	Actions.register(&"sync.push", "Push", "Sync",
			func() -> void: ops.call().push(), PackedStringArray(["Ctrl+P"]), can_push)
	Actions.register(&"sync.force_push", "Force push (with lease)…", "Sync",
			func() -> void: ops.call().force_push(), PackedStringArray(), can_push)
	Actions.register(&"sync.cancel", "Cancel the running git operation", "Sync",
			func() -> void: _jobs_bar.cancel_current(), PackedStringArray(),
			func() -> bool: return _jobs_bar.job_count() > 0)
	Actions.register(&"operation.abort", "Abort the operation in progress…", "Repository",
			func() -> void: ops.call().abort_operation(), PackedStringArray(),
			func() -> bool: return is_ready.call() and not session.call().operation().is_empty())
	Actions.register(&"repo.open_in_editor", "Open in editor", "Repository",
			func() -> void: ops.call().open_in_editor(), PackedStringArray(["Ctrl+Shift+E"]), is_ready)
	Actions.register(&"repo.open_terminal", "Open terminal here", "Repository",
			func() -> void: ops.call().open_terminal(), PackedStringArray(["Ctrl+Shift+T"]), is_ready)


## Branch, tag and commit actions. They act on the sidebar's ref or the
## history's commit (`RepoTab.ref_target` / `commit_target`), else on HEAD.
func _register_branch_actions() -> void:
	var is_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session.is_ready()
	var ops: Callable = func() -> RepoOps: return current_page().ops()
	var ref: Callable = func() -> Dictionary:
		return current_page().ref_target() if is_ready.call() else {}
	var commit: Callable = func() -> Dictionary:
		return current_page().commit_target() if is_ready.call() else {}
	var ref_is: Callable = func(type: String) -> bool: return String(ref.call().get("type", "")) == type
	# A local branch: the sidebar's, else the checked-out one.
	var branch: Callable = func() -> String:
		var target: Dictionary = ref.call()
		if not target.is_empty():
			return String(target["short"]) if String(target["type"]) == "branch" else ""
		return current_page().session.current_branch() if is_ready.call() else ""
	var has_head: Callable = func() -> bool:
		return is_ready.call() and not String(current_page().session.status().get("oid", "")).is_empty()

	Actions.register(&"branch.new", "New branch…", "Branches",
			func() -> void:
				var start: Array = _start_point(ref.call(), commit.call())
				ops.call().new_branch(start[0], start[1]),
			PackedStringArray(["Ctrl+Shift+N"]), has_head)
	Actions.register(&"branch.checkout", "Check out", "Branches",
			func() -> void:
				var target: Dictionary = ref.call()
				if String(target["type"]) == "remote":
					ops.call().checkout_remote(String(target["name"]))
				else:
					ops.call().checkout_branch(String(target["short"])),
			PackedStringArray(),
			func() -> bool:
				return ref_is.call("remote") or (ref_is.call("branch") and not bool(ref.call()["is_head"])))
	Actions.register(&"branch.rename", "Rename branch…", "Branches",
			func() -> void: ops.call().rename_branch(branch.call()), PackedStringArray(["F2"]),
			func() -> bool: return not String(branch.call()).is_empty())
	Actions.register(&"branch.delete", "Delete branch…", "Branches",
			func() -> void: ops.call().delete_branch(String(ref.call()["short"])), PackedStringArray(),
			func() -> bool: return ref_is.call("branch") and not bool(ref.call()["is_head"]))
	Actions.register(&"branch.set_upstream", "Set upstream…", "Branches",
			func() -> void: ops.call().set_upstream(branch.call()), PackedStringArray(),
			func() -> bool:
				return not String(branch.call()).is_empty() and not current_page().session.remotes().is_empty())
	Actions.register(&"tag.new", "New tag…", "Tags",
			func() -> void:
				var start: Array = _start_point(ref.call(), commit.call())
				ops.call().new_tag(start[0], start[1]),
			PackedStringArray(), has_head)
	Actions.register(&"tag.push", "Push tag", "Tags",
			func() -> void: ops.call().push_tag(String(ref.call()["short"])), PackedStringArray(),
			func() -> bool: return ref_is.call("tag") and not current_page().session.default_remote().is_empty())
	Actions.register(&"tag.delete", "Delete tag…", "Tags",
			func() -> void: ops.call().delete_tag(String(ref.call()["short"])), PackedStringArray(),
			func() -> bool: return ref_is.call("tag"))
	# Commit actions take the history's commit, or a sidebar tag's.
	var target_commit: Callable = func() -> Dictionary:
		var target: Dictionary = ref.call()
		if String(target.get("type", "")) == "tag":
			return {"hash": String(target["commit"]), "subject": String(target["short"])}
		return commit.call() if target.is_empty() else {}
	var not_head: Callable = func() -> bool:
		var target: Dictionary = target_commit.call()
		return not target.is_empty() \
				and String(target["hash"]) != String(current_page().session.status().get("oid", ""))
	Actions.register(&"commit.checkout", "Check out commit (detached)…", "History",
			func() -> void: ops.call().checkout_commit(String(target_commit.call()["hash"])),
			PackedStringArray(), not_head)
	Actions.register(&"commit.cherry_pick", "Cherry-pick commit…", "History",
			func() -> void:
				var target: Dictionary = target_commit.call()
				ops.call().cherry_pick(String(target["hash"]), String(target["subject"])),
			PackedStringArray(),
			func() -> bool: return not_head.call() and current_page().session.operation().is_empty())
	Actions.register(&"commit.copy_hash", "Copy commit hash", "History",
			func() -> void: ops.call().copy_hash(String(target_commit.call()["hash"])),
			PackedStringArray(),
			func() -> bool: return not target_commit.call().is_empty())


## Where a new branch or tag starts: `[commit-ish, label]` from the sidebar's
## ref, the history's commit, or HEAD.
func _start_point(ref: Dictionary, commit: Dictionary) -> Array:
	if not ref.is_empty():
		return [String(ref["name"]), String(ref["short"])]
	if not commit.is_empty():
		var hash: String = String(commit["hash"])
		return [hash, "%s “%s”" % [hash.left(7), String(commit["subject"])]]
	var head: String = current_page().session.current_branch()
	return ["HEAD", head if not head.is_empty() else "HEAD"]


## Buttons for a toast about `error` in `repo_path` (`Toasts.fix_provider`).
func _error_fixes(repo_path: String, error: Dictionary) -> Array[Dictionary]:
	var fixes: Array[Dictionary] = []
	var page: RepoTab = page_for(repo_path)
	if page == null:
		return fixes
	var ops: RepoOps = page.ops()
	var command: String = String(error.get("command", ""))
	match String(error.get("kind", "")):
		"non_fast_forward":
			fixes.append({"label": "Pull", "run": func() -> void: ops.pull()})
		"diverged":
			fixes.append({"label": "Pull (merge)", "run": func() -> void: ops.pull("merge")})
			fixes.append({"label": "Pull (rebase)", "run": func() -> void: ops.pull("rebase")})
		"conflict":
			if command.begins_with("cherry-pick") or command.begins_with("pull"):
				fixes.append({"label": "Abort", "run": func() -> void: page.session.abort_operation()})
		"checked_out_elsewhere":
			var stderr: String = String(error.get("stderr", ""))
			var at: int = stderr.find(" at '")
			if at >= 0:
				var path: String = stderr.substr(at + 5).get_slice("'", 0)
				fixes.append({"label": "Open that worktree", "run": func() -> void: open_repo(path)})
	return fixes


## Errors the tab follows up with a dialog need no toast (`Toasts.error_filter`).
func _error_handled_elsewhere(repo_path: String, error: Dictionary) -> bool:
	var page: RepoTab = page_for(repo_path)
	return page != null and page.ops().handles_error(error)


func _toggle_side_by_side() -> void:
	var value: bool = not Core.diff_side_by_side()
	Core.set_diff_side_by_side(value)
	get_tree().call_group(DiffPanel.GROUP, &"set_side_by_side", value)


func _toggle_sidebars() -> void:
	for p: RepoTab in _pages:
		p.toggle_sidebar()


func _set_theme(choice: String) -> void:
	Core.set_theme_choice(choice)
	ThemeManager.apply(self)


func _on_system_theme_changed() -> void:
	if Core.theme_choice() == "system":
		ThemeManager.apply(self)


func _show_open_dialog() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.use_native_dialog = true
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Open repository"
	dialog.dir_selected.connect(func(path: String) -> void: open_repo(path))
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


## Palette entries besides actions: check out a branch of the current tab,
## switch to a tab, open a recent repository.
func _palette_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var page: RepoTab = current_page()
	if page != null and page.session.is_ready():
		for ref: Dictionary in page.session.branch_refs():
			if bool(ref["is_head"]):
				continue
			var local: bool = String(ref["kind"]) == "branch"
			var name: String = String(ref["short_name"])
			var full: String = String(ref["name"])
			var ops: RepoOps = page.ops()
			entries.append({
				"label": "Check out: " + name,
				"detail": "branch" if local else "remote branch",
				"run": (func() -> void: ops.checkout_branch(name)) if local
						else (func() -> void: ops.checkout_remote(full)),
			})
	for i: int in _pages.size():
		var index: int = i
		entries.append({
			"label": "Go to tab: " + _pages[i].title(),
			"detail": "",
			"run": func() -> void: _tabs.current_tab = index,
		})
	var open_paths: PackedStringArray = PackedStringArray()
	for p: RepoTab in _pages:
		open_paths.append(p.repo_path())
	for path: String in Core.recent_repos():
		if path in open_paths:
			continue
		entries.append({
			"label": "Open recent: " + path.get_file(),
			"detail": path,
			"run": func() -> void: open_repo(path),
		})
	return entries
