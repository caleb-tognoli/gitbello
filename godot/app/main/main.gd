class_name Main
extends PanelContainer
## App shell (PLAN §4): the menu bar, one tab per repository (its worktrees
## are chips inside it), the welcome screen, the git command log, the status
## bar, toasts and the command palette. Every user operation is an action in
## `Actions`.

const MIN_WINDOW_SIZE: Vector2i = Vector2i(960, 600)
const REPO_ARG: String = "--repo="
const REPO_TAB: PackedScene = preload("res://app/repo_tab/repo_tab.tscn")
const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
## Worktree chips Ctrl+1 … Ctrl+9 select.
const CHIP_SHORTCUTS: int = 9

var _pages: Array[RepoTab] = []
var _current: int = -1
var _feedback: Feedback = Feedback.new()
var _settings_form: FormDialog = null
var _remotes_dialog: RemotesDialog = RemotesDialog.new()
var _tags_dialog: TagsDialog = TagsDialog.new()
var _about: AcceptDialog = AcceptDialog.new()
## Spins the busy tabs' icons.
var _spinner: Timer = Timer.new()
var _spin_frame: int = 0

@onready var _menu_strip: Control = %MenuStrip
@onready var _menu_bar: AppMenuBar = %MenuBar
@onready var _tab_strip: Control = %TabStrip
@onready var _tabs: TabBar = %Tabs
@onready var _add_button: Button = %AddButton
@onready var _content: Control = %Content
@onready var _welcome: Welcome = %Welcome
@onready var _git_log: GitLogPanel = %GitLog
@onready var _status_bar: Control = %StatusBar
@onready var _status_label: Label = %StatusLabel
@onready var _version_label: Label = %VersionLabel
@onready var _toasts: Toasts = %Toasts
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
	_feedback.name = "Feedback"
	_feedback.toasts = _toasts
	_feedback.busy_changed.connect(func(_session: RepoSession) -> void: _update_tab_icons())
	add_child(_feedback)
	for dialog: Window in [_remotes_dialog, _tags_dialog, _about]:
		add_child(dialog)
	_spinner.wait_time = BigButton.SPIN_SECONDS
	_spinner.timeout.connect(func() -> void:
		_spin_frame = (_spin_frame + 1) % AppTheme.SPINNER_FRAMES
		_update_tab_icons())
	add_child(_spinner)
	_apply_theme()
	_palette.dynamic_entries = _palette_entries
	_settings_form = FORM.instantiate() as FormDialog
	add_child(_settings_form)
	_toasts.fix_provider = _error_fixes
	_toasts.error_filter = _error_handled_elsewhere

	_tabs.tab_changed.connect(_on_tab_changed)
	_tabs.tab_close_pressed.connect(close_tab)
	_tabs.active_tab_rearranged.connect(_on_tab_rearranged)
	_add_button.icon = AppTheme.icon(&"Add")
	_add_button.pressed.connect(func() -> void: Actions.run_action(&"repo.open"))
	_welcome.open_requested.connect(func() -> void: Actions.run_action(&"repo.open"))
	_welcome.recent_chosen.connect(open_repo)
	_register_actions()
	_menu_bar.dynamic_menus["Open recent"] = _recent_entries
	_menu_strip.visible = not _menu_bar.is_native_menu()

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
	elif what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()
		_update_tab_icons()


static func repo_from_args(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(REPO_ARG):
			return arg.trim_prefix(REPO_ARG)
	return ""


# --- Tabs -------------------------------------------------------------------

## Opens `path` (a repository or one of its worktrees): focuses the tab of
## its repository and shows that worktree, or opens a new tab.
func open_repo(path: String) -> RepoTab:
	for i: int in _pages.size():
		if _pages[i].has_worktree(path):
			_tabs.current_tab = i
			_pages[i].show_worktree(path)
			return _pages[i]
	var session: RepoSession = Core.open_session(path)
	if session == null:
		_toasts.show_toast("Cannot open repository", Core.start_error())
		return null
	for i: int in _pages.size():
		if _pages[i].view_for(session.repo_path()) != null:
			_tabs.current_tab = i
			_pages[i].show_worktree(session.repo_path())
			return _pages[i]
	var page: RepoTab = REPO_TAB.instantiate() as RepoTab
	page.feedback = _feedback
	_content.add_child(page)
	page.setup(session)
	page.state_changed.connect(_on_page_state.bind(page))
	page.notice.connect(func(title: String, message: String) -> void: _toasts.show_toast(title, message))
	_pages.append(page)
	_tabs.add_tab(page.title())
	_tabs.set_tab_metadata(_tabs.tab_count - 1, page)
	_tabs.current_tab = _pages.size() - 1
	_on_page_state(page)
	_update_view()
	_save_tabs()
	_welcome.refresh()
	return page


func close_tab(index: int) -> void:
	if index < 0 or index >= _pages.size():
		return
	var page: RepoTab = _pages[index]
	_pages.remove_at(index)
	page.close_all()
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


## The selected worktree's view in the current tab, or null.
func current_view() -> WorktreeView:
	var page: RepoTab = current_page()
	return page.active_view() if page != null else null


func tab_bar() -> TabBar:
	return _tabs


func menu_bar() -> AppMenuBar:
	return _menu_bar


func git_log() -> GitLogPanel:
	return _git_log


func toasts() -> Toasts:
	return _toasts


func feedback() -> Feedback:
	return _feedback


func palette() -> CommandPalette:
	return _palette


func remotes_dialog() -> RemotesDialog:
	return _remotes_dialog


func tags_dialog() -> TagsDialog:
	return _tags_dialog


## The tab of repository or worktree `repo_path` (a session key), or null.
func page_for(repo_path: String) -> RepoTab:
	for p: RepoTab in _pages:
		if p.view_for(repo_path) != null or p.has_worktree(repo_path):
			return p
	return null


## Saved tabs are the selected worktree of each repository; tabs saved
## before M6.5 may be several worktrees of one repository, which open as
## chips of one tab (see `_merge_duplicates`).
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
		if not p.has_error() and not p.repo_path().is_empty():
			paths.append(p.repo_path())
	var error: String = Core.save_tabs(paths, _tabs.current_tab)
	if not error.is_empty():
		_toasts.show_toast("Cannot save settings", error)


func _update_view() -> void:
	_welcome.visible = _pages.is_empty()
	_tab_strip.visible = not _pages.is_empty()
	for i: int in _pages.size():
		_pages[i].visible = i == _tabs.current_tab
	var view: WorktreeView = current_view()
	_status_label.text = view.worktree_path() if view != null else "No repository open"


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


func _on_page_state(page: RepoTab) -> void:
	var index: int = _pages.find(page)
	if index < 0:
		return
	if _merge_duplicates(page):
		return
	_tabs.set_tab_title(index, page.title())
	_tabs.set_tab_tooltip(index, page.summary())
	_update_tab_icons()
	if index == _tabs.current_tab:
		_update_view()
		_save_tabs()


## Two tabs of one repository (known once its worktrees are read) become one:
## the later tab's worktrees move into the earlier one. Returns whether
## `page` was merged away.
func _merge_duplicates(page: RepoTab) -> bool:
	if page.main_worktree().is_empty():
		return false
	for other: RepoTab in _pages:
		if other == page or other.main_worktree().is_empty() or not Paths.same(other.key(), page.key()):
			continue
		var keep: RepoTab = other if _pages.find(other) < _pages.find(page) else page
		var drop: RepoTab = page if keep == other else other
		var was_current: bool = current_page() == drop
		var shown: String = drop.active_view().worktree_path() if drop.active_view() != null else ""
		for v: WorktreeView in drop.release_views():
			keep.adopt(v)
		var index: int = _pages.find(drop)
		_pages.remove_at(index)
		drop.queue_free()
		_tabs.remove_tab(index)
		if was_current:
			_tabs.current_tab = _pages.find(keep)
			if not shown.is_empty():
				keep.show_worktree(shown)
		_update_view()
		_save_tabs()
		return drop == page
	return false


## Each tab's icon: the spinner while its repository runs a job, else the
## attention dot (PLAN §4 Repo tabs).
func _update_tab_icons() -> void:
	var spinning: bool = false
	for i: int in _pages.size():
		var page: RepoTab = _pages[i]
		var sessions: Array[RepoSession] = []
		for v: WorktreeView in page.views():
			sessions.append(v.session)
		if _feedback.any_busy(sessions):
			spinning = true
			_tabs.set_tab_icon(i, AppTheme.spinner(_spin_frame, ThemeManager.light))
			continue
		var color_name: StringName = {
			RepoTab.Attention.CONFLICT: &"conflict_color",
			RepoTab.Attention.CHANGES: &"changes_color",
			RepoTab.Attention.SYNC: &"sync_color",
		}.get(page.attention(), &"")
		_tabs.set_tab_icon(i, AppTheme.dot(get_theme_color(color_name, &"RepoTabs")) if color_name != &"" else null)
	if spinning and _spinner.is_stopped():
		_spinner.start()
	elif not spinning and not _spinner.is_stopped():
		_spinner.stop()


func _on_files_dropped(files: PackedStringArray) -> void:
	for file: String in files:
		open_repo(file if DirAccess.dir_exists_absolute(file) else file.get_base_dir())


func _apply_theme() -> void:
	_git_log.custom_minimum_size.y = float(get_theme_constant(&"height", &"GitLogPanel"))
	_tabs.max_tab_width = get_theme_constant(&"max_tab_width", &"Shell")
	_toasts.offset_bottom = -float(get_theme_constant(&"bottom_margin", &"Toasts"))


# --- Actions ----------------------------------------------------------------

func _register_actions() -> void:
	var has_tab: Callable = func() -> bool: return not _pages.is_empty()
	var many_tabs: Callable = func() -> bool: return _pages.size() > 1
	var no_repo: Callable = func() -> String: return "Open a repository first."
	Actions.register(&"app.command_palette", "Command palette", "App",
			_palette.open, PackedStringArray(["Ctrl+K", "Ctrl+Shift+P"]))
	Actions.register(&"app.keyboard_shortcuts", "Keyboard shortcuts…", "App",
			_shortcuts_dialog.open, PackedStringArray(["Ctrl+Comma"]))
	Actions.register(&"app.quit", "Quit", "App",
			func() -> void: get_tree().quit(), PackedStringArray(["Ctrl+Q"]))
	Actions.register(&"app.about", "About gitbello", "App", _show_about)
	Actions.register(&"repo.open", "Open repository…", "Repository",
			_show_open_dialog, PackedStringArray(["Ctrl+O"]))
	Actions.register(&"repo.refresh", "Refresh", "Repository",
			func() -> void: current_page().session.refresh(), PackedStringArray(["F5"]), has_tab, no_repo)
	Actions.register(&"tab.close", "Close tab", "Tabs",
			func() -> void: close_tab(_tabs.current_tab), PackedStringArray(["Ctrl+W"]), has_tab, no_repo)
	Actions.register(&"tab.next", "Next tab", "Tabs",
			func() -> void: _tabs.current_tab = (_tabs.current_tab + 1) % _pages.size(),
			PackedStringArray(["Ctrl+Tab"]), many_tabs)
	Actions.register(&"tab.previous", "Previous tab", "Tabs",
			func() -> void: _tabs.current_tab = (_tabs.current_tab - 1 + _pages.size()) % _pages.size(),
			PackedStringArray(["Ctrl+Shift+Tab"]), many_tabs)
	Actions.register(&"view.toggle_git_log", "Git command log", "View",
			func() -> void: _git_log.visible = not _git_log.visible,
			PackedStringArray(["Ctrl+Shift+L"]))
	Actions.register(&"view.history", "History", "View",
			func() -> void: current_page().show_view(WorktreeView.View.HISTORY),
			PackedStringArray(["Ctrl+Shift+H"]), has_tab, no_repo)
	Actions.register(&"view.changes", "Changes", "View",
			func() -> void: current_page().show_view(WorktreeView.View.CHANGES),
			PackedStringArray(["Ctrl+Shift+G"]), has_tab, no_repo)
	for i: int in CHIP_SHORTCUTS:
		var index: int = i
		var action: ActionRegistry.Action = Actions.register(StringName("worktree.select_%d" % (i + 1)),
				"Show worktree %d" % (i + 1), "Worktrees",
				func() -> void: current_page().select_chip(index), PackedStringArray(["Ctrl+%d" % (i + 1)]),
				func() -> bool: return current_page() != null and not current_page().strip().path_at(index).is_empty())
		action.hidden = true
	_register_change_actions()
	_register_sync_actions()
	_register_branch_actions()
	_register_worktree_actions()
	Actions.register(&"app.settings", "Settings…", "App", _open_settings)
	Actions.register(&"diff.toggle_side_by_side", "Side-by-side diff", "View",
			_toggle_side_by_side, PackedStringArray(["Ctrl+Shift+D"]))
	for choice: String in ["system", "light", "dark"]:
		Actions.register(StringName("view.theme_" + choice), "Theme: %s" % choice.capitalize(), "View",
				_set_theme.bind(choice))


## A disabled reason that is always `text`.
static func _says(text: String) -> Callable:
	return func() -> String: return text


## Changes-panel actions; they run on the current worktree's changes view.
func _register_change_actions() -> void:
	var repo_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session != null and page.session.is_ready()
	var in_changes: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session != null and page.session.is_ready() \
				and page.view == WorktreeView.View.CHANGES
	var changes: Callable = func() -> ChangesView: return current_page().changes()
	Actions.register(&"changes.stage_selected", "Stage or unstage the selection", "Changes",
			func() -> void: changes.call().stage_selected(), PackedStringArray(), in_changes)
	Actions.register(&"changes.stage_all", "Stage all changes", "Changes",
			func() -> void: changes.call().stage_all(), PackedStringArray(["Ctrl+Shift+S"]), repo_ready)
	Actions.register(&"changes.unstage_all", "Unstage all changes", "Changes",
			func() -> void: changes.call().unstage_all(), PackedStringArray(["Ctrl+Shift+U"]), repo_ready)
	Actions.register(&"changes.focus_message", "Write commit message", "Changes",
			func() -> void:
				current_page().show_view(WorktreeView.View.CHANGES)
				changes.call().focus_message(),
			PackedStringArray(["Ctrl+Shift+M"]), repo_ready)
	Actions.register(&"changes.discard", "Discard selected changes…", "Changes",
			func() -> void: changes.call().discard_selection(), PackedStringArray(["Delete"]), in_changes)
	Actions.register(&"changes.undo_discard", "Undo last discard", "Changes",
			func() -> void: changes.call().undo_discard(), PackedStringArray(["Ctrl+Z"]),
			func() -> bool: return in_changes.call() and current_page().changes().can_undo_discard(),
			_says("There is no discard to undo."))
	var amend: ActionRegistry.Action = Actions.register(&"changes.toggle_amend", "Toggle amend last commit", "Changes",
			func() -> void: changes.call().toggle_amend(), PackedStringArray(["Ctrl+Shift+A"]), in_changes)
	amend.in_text_fields = true
	var commit: ActionRegistry.Action = Actions.register(&"changes.commit", "Commit", "Changes",
			func() -> void: changes.call().commit(), PackedStringArray(["Ctrl+Enter"]),
			func() -> bool: return in_changes.call() and current_page().changes().commit_box().can_commit())
	commit.in_text_fields = true


## Sync and worktree-wide actions; they run on the current worktree.
func _register_sync_actions() -> void:
	var is_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session != null and page.session.is_ready()
	var session: Callable = func() -> RepoSession: return current_page().session
	var ops: Callable = func() -> RepoOps: return current_page().ops()
	var no_remote: Callable = func() -> String:
		if not is_ready.call():
			return "Open a repository first."
		return "This repository has no remote. Add one with Repository → Remotes…" \
				if session.call().remotes().is_empty() else ""
	var pull_reason: Callable = func() -> String:
		var why: String = String(no_remote.call())
		return why if not why.is_empty() else "The current branch does not follow a remote branch."
	var push_reason: Callable = func() -> String:
		var why: String = String(no_remote.call())
		return why if not why.is_empty() else "There is no branch checked out."
	var can_pull: Callable = func() -> bool: return is_ready.call() and session.call().can_pull()
	var can_push: Callable = func() -> bool: return is_ready.call() and session.call().can_push()
	Actions.register(&"sync.sync", "Sync", "Sync", func() -> void: ops.call().sync(), PackedStringArray(["Ctrl+Shift+Y"]),
			func() -> bool: return is_ready.call() and session.call().can_fetch(), no_remote)
	Actions.register(&"sync.fetch", "Fetch", "Sync",
			func() -> void: ops.call().fetch(), PackedStringArray(["Ctrl+Shift+F"]),
			func() -> bool: return is_ready.call() and session.call().can_fetch(), no_remote)
	Actions.register(&"sync.pull", "Pull", "Sync",
			func() -> void: ops.call().pull(), PackedStringArray(["Ctrl+L"]), can_pull, pull_reason)
	for mode: String in ["ff-only", "merge", "rebase"]:
		var label: String = {"ff-only": "Pull (fast-forward only)", "merge": "Pull (merge)", "rebase": "Pull (rebase)"}[mode]
		Actions.register(StringName("sync.pull_" + mode.replace("-", "_")), label, "Sync",
				func() -> void: ops.call().pull(mode), PackedStringArray(), can_pull, pull_reason)
	Actions.register(&"sync.push", "Push", "Sync",
			func() -> void: ops.call().push(), PackedStringArray(["Ctrl+P"]), can_push, push_reason)
	Actions.register(&"sync.force_push", "Force push (with lease)…", "Sync",
			func() -> void: ops.call().force_push(), PackedStringArray(), can_push, push_reason)
	Actions.register(&"sync.cancel", "Cancel the running git operation", "Sync",
			func() -> void: _feedback.cancel_latest(session.call()), PackedStringArray(),
			func() -> bool: return is_ready.call() and _feedback.is_busy(session.call()))
	Actions.register(&"operation.abort", "Abort the operation in progress…", "Repository",
			func() -> void: ops.call().abort_operation(), PackedStringArray(),
			func() -> bool: return is_ready.call() and not session.call().operation().is_empty())
	Actions.register(&"repo.open_in_editor", "Open in editor", "Repository",
			func() -> void: ops.call().open_in_editor(), PackedStringArray(["Ctrl+Shift+E"]), is_ready)
	Actions.register(&"repo.open_terminal", "Open terminal here", "Repository",
			func() -> void: ops.call().open_terminal(), PackedStringArray(["Ctrl+Shift+T"]), is_ready)
	Actions.register(&"repo.show_in_file_manager", "Show in file manager", "Repository",
			func() -> void: ops.call().show_in_file_manager(), PackedStringArray(), is_ready)
	Actions.register(&"repo.remotes", "Remotes…", "Repository",
			func() -> void: _remotes_dialog.open(ops.call()), PackedStringArray(), is_ready)
	Actions.register(&"repo.tags", "Tags…", "Repository",
			func() -> void: _tags_dialog.open(ops.call()), PackedStringArray(), is_ready)


## Branch, tag and commit actions. They act on the ref of a context menu or
## the history's commit (`RepoTab.ref_target` / `commit_target`), else on HEAD.
func _register_branch_actions() -> void:
	var is_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session != null and page.session.is_ready()
	var ops: Callable = func() -> RepoOps: return current_page().ops()
	var ref: Callable = func() -> Dictionary:
		return current_page().ref_target() if is_ready.call() else {}
	var commit: Callable = func() -> Dictionary:
		return current_page().commit_target() if is_ready.call() else {}
	var ref_is: Callable = func(type: String) -> bool: return String(ref.call().get("type", "")) == type
	# A local branch: the menu's, else the checked-out one.
	var branch: Callable = func() -> String:
		var target: Dictionary = ref.call()
		if not target.is_empty():
			return String(target["short"]) if String(target["type"]) == "branch" else ""
		return current_page().session.current_branch() if is_ready.call() else ""
	var has_head: Callable = func() -> bool:
		return is_ready.call() and not String(current_page().session.status().get("oid", "")).is_empty()

	Actions.register(&"branch.switch", "Switch branch…", "Branches",
			func() -> void: current_view().open_branches(), PackedStringArray(["Ctrl+B"]), is_ready)
	Actions.register(&"branch.new", "New branch…", "Branches",
			func() -> void:
				var start: Array = _start_point(ref.call(), commit.call())
				ops.call().new_branch(start[0], start[1]),
			PackedStringArray(["Ctrl+Shift+N"]), has_head, _says("There is no commit to start a branch from yet."))
	Actions.register(&"branch.checkout", "Check out", "Branches",
			func() -> void:
				var target: Dictionary = ref.call()
				if not String(target.get("worktree", "")).is_empty():
					current_page().show_worktree(String(target["worktree"]))
				elif String(target["type"]) == "remote":
					ops.call().checkout_remote(String(target["name"]))
				else:
					ops.call().checkout_branch(String(target["short"])),
			PackedStringArray(),
			func() -> bool:
				return ref_is.call("remote") or (ref_is.call("branch") and not bool(ref.call()["is_head"])))
	Actions.register(&"branch.rename", "Rename branch…", "Branches",
			func() -> void: ops.call().rename_branch(branch.call()), PackedStringArray(["F2"]),
			func() -> bool: return not String(branch.call()).is_empty(), _says("There is no branch checked out."))
	# A branch checked out in another worktree cannot be deleted; remove the
	# worktree first.
	Actions.register(&"branch.delete", "Delete branch…", "Branches",
			func() -> void: ops.call().delete_branch(String(ref.call()["short"])), PackedStringArray(),
			func() -> bool:
				return ref_is.call("branch") and not bool(ref.call()["is_head"]) \
						and String(ref.call().get("worktree", "")).is_empty())
	Actions.register(&"branch.set_upstream", "Set upstream…", "Branches",
			func() -> void: ops.call().set_upstream(branch.call()), PackedStringArray(),
			func() -> bool: return not String(branch.call()).is_empty() and not current_page().session.remotes().is_empty(),
			_says("There is no remote to follow."))
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
	# Commit actions take the history's commit, or a tag's.
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


## Worktree actions: the new-task and cleanup flows, and a chip's show,
## open, lock, remove and prune.
func _register_worktree_actions() -> void:
	var is_ready: Callable = func() -> bool:
		var page: RepoTab = current_page()
		return page != null and page.session != null and page.session.is_ready()
	var ops: Callable = func() -> RepoOps: return current_page().ops()
	var worktree: Callable = func() -> Dictionary:
		var target: Dictionary = current_page().ref_target() if is_ready.call() else {}
		return target if String(target.get("type", "")) == "worktree" else {}
	var openable: Callable = func() -> bool:
		var wt: Dictionary = worktree.call()
		return not wt.is_empty() and not bool(wt["prunable"])
	var has_missing: Callable = func() -> bool:
		if not is_ready.call():
			return false
		for wt: Dictionary in current_page().session.worktrees():
			if bool(wt["prunable"]):
				return true
		return false
	Actions.register(&"task.new", "New task…", "Worktrees",
			func() -> void: ops.call().new_task(), PackedStringArray(["Ctrl+T"]),
			func() -> bool: return is_ready.call() and not current_page().session.main_worktree().is_empty())
	Actions.register(&"worktree.cleanup", "Clean up merged worktrees…", "Worktrees",
			func() -> void: ops.call().cleanup_worktrees(), PackedStringArray(),
			func() -> bool: return is_ready.call() and current_page().session.worktrees().size() > 1,
			_says("There are no other worktrees."))
	Actions.register(&"worktree.add_existing", "Add worktree for a branch…", "Worktrees",
			func() -> void: ops.call().add_existing_worktree(), PackedStringArray(), is_ready)
	Actions.register(&"worktree.prune", "Prune missing worktrees", "Worktrees",
			func() -> void: ops.call().prune_worktrees(), PackedStringArray(), has_missing,
			_says("No worktree folder is missing."))
	Actions.register(&"worktree.open", "Show worktree", "Worktrees",
			func() -> void: current_page().show_worktree(String(worktree.call()["path"])), PackedStringArray(),
			func() -> bool: return openable.call() and not bool(worktree.call()["is_head"]))
	Actions.register(&"worktree.open_in_editor", "Open in editor", "Worktrees",
			func() -> void: ops.call().open_in_editor(String(worktree.call()["path"])), PackedStringArray(),
			openable)
	Actions.register(&"worktree.open_terminal", "Open terminal", "Worktrees",
			func() -> void: ops.call().open_terminal(String(worktree.call()["path"])), PackedStringArray(),
			openable)
	Actions.register(&"worktree.show_in_file_manager", "Show in file manager", "Worktrees",
			func() -> void: ops.call().show_in_file_manager(String(worktree.call()["path"])), PackedStringArray(),
			openable)
	Actions.register(&"worktree.copy_path", "Copy path", "Worktrees",
			func() -> void: DisplayServer.clipboard_set(String(worktree.call()["path"])), PackedStringArray(),
			func() -> bool: return not worktree.call().is_empty())
	Actions.register(&"worktree.lock", "Lock…", "Worktrees",
			func() -> void: ops.call().lock_worktree(String(worktree.call()["path"])), PackedStringArray(),
			func() -> bool:
				var wt: Dictionary = worktree.call()
				return not wt.is_empty() and not bool(wt["is_main"]) and not bool(wt["locked"]))
	Actions.register(&"worktree.unlock", "Unlock", "Worktrees",
			func() -> void: ops.call().unlock_worktree(String(worktree.call()["path"])), PackedStringArray(),
			func() -> bool: return bool(worktree.call().get("locked", false)))
	Actions.register(&"worktree.remove", "Remove…", "Worktrees",
			func() -> void: ops.call().remove_worktree(worktree.call()), PackedStringArray(),
			func() -> bool:
				var wt: Dictionary = worktree.call()
				return openable.call() and not bool(wt["is_main"]) and not bool(wt["is_head"]))


## The Settings dialog: pull mode, auto-fetch, editor, terminal, the
## worktree folder template and the accent colour.
func _open_settings() -> void:
	var settings: Dictionary = Core.settings()
	var modes: PackedStringArray = PackedStringArray(["ff-only", "merge", "rebase"])
	_settings_form.begin("Settings", "Save", _save_settings)
	_settings_form.add_choice("pull_mode", "Pull", modes, modes.find(String(settings["pull_mode"])))
	_settings_form.add_line("auto_fetch_minutes", "Auto-fetch", str(int(settings["auto_fetch_minutes"])))
	_settings_form.add_note("Minutes between fetches; 0 turns it off.")
	_settings_form.add_line("editor_command", "Editor", String(settings["editor_command"]))
	_settings_form.add_note("{path} is replaced by the folder.")
	_settings_form.add_line("terminal_command", "Terminal", String(settings["terminal_command"]), false,
			"The platform's terminal")
	_settings_form.add_line("worktree_template", "New task folders", String(settings["worktree_template"]))
	_settings_form.add_note("{repo_parent}, {repo_name}, {repo}, {branch_slug} and {branch} are filled in.")
	_settings_form.add_color("accent", "Accent colour", ThemeManager.configured_accent(), AppTheme.ACCENT_PRESETS)
	_settings_form.validator = func(values: Dictionary) -> String:
		var minutes: String = String(values["auto_fetch_minutes"])
		return "" if minutes.is_valid_int() and int(minutes) >= 0 else "Enter a whole number of minutes."
	_settings_form.open()


func settings_form() -> FormDialog:
	return _settings_form


func _save_settings(values: Dictionary) -> void:
	var settings: Dictionary = values.duplicate()
	settings["auto_fetch_minutes"] = int(String(values["auto_fetch_minutes"]))
	if Color(String(values["accent"])).is_equal_approx(AppTheme.DEFAULT_ACCENT):
		settings["accent"] = ""
	var error: String = Core.set_settings(settings)
	if not error.is_empty():
		_toasts.show_toast("Settings not saved", error)
		return
	if not ThemeManager.configured_accent().is_equal_approx(ThemeManager.accent):
		ThemeManager.apply(self)
	_toasts.show_success("Settings saved")


## Where a new branch or tag starts: `[commit-ish, label]` from the menu's
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
	var view: WorktreeView = page.view_for(repo_path)
	if view == null:
		return fixes
	var ops: RepoOps = view.ops()
	var command: String = String(error.get("command", ""))
	match String(error.get("kind", "")):
		"non_fast_forward":
			fixes.append({"label": "Pull", "run": func() -> void: ops.pull()})
		"diverged":
			fixes.append({"label": "Pull (merge)", "run": func() -> void: ops.pull("merge")})
			fixes.append({"label": "Pull (rebase)", "run": func() -> void: ops.pull("rebase")})
		"conflict":
			if command.begins_with("cherry-pick") or command.begins_with("pull"):
				fixes.append({"label": "Abort", "run": func() -> void: view.session.abort_operation()})
		"checked_out_elsewhere":
			var stderr: String = String(error.get("stderr", ""))
			var at: int = stderr.find(" at '")
			if at >= 0:
				var path: String = stderr.substr(at + 5).get_slice("'", 0)
				fixes.append({"label": "Show that worktree", "run": func() -> void: open_repo(path)})
	return fixes


## Errors a dialog follows up need no toast (`Toasts.error_filter`).
func _error_handled_elsewhere(repo_path: String, error: Dictionary) -> bool:
	var page: RepoTab = page_for(repo_path)
	var view: WorktreeView = page.view_for(repo_path) if page != null else null
	return view != null and view.ops().handles_error(error)


func _toggle_side_by_side() -> void:
	var value: bool = not Core.diff_side_by_side()
	Core.set_diff_side_by_side(value)
	get_tree().call_group(DiffPanel.GROUP, &"set_side_by_side", value)


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


func _show_about() -> void:
	_about.title = "About gitbello"
	_about.dialog_text = "gitbello %s\nA fast Git GUI for many repositories and worktrees.\n\ngit %s · Godot %s" % [
		Core.core_version(), Core.git_version(), Engine.get_version_info()["string"]]
	_about.popup_centered()


## File → Open recent: repositories not open now.
func _recent_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for path: String in Core.recent_repos():
		if page_for(path) != null:
			continue
		entries.append({"label": path.get_file(), "tooltip": path, "run": func() -> void: open_repo(path)})
	return entries


## Palette entries besides actions: check out a branch of the current
## worktree, show a worktree of an open repository, open a recent repository.
func _palette_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var page: RepoTab = current_page()
	if page != null and page.session != null and page.session.is_ready():
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
		var tab: RepoTab = _pages[i]
		entries.append({
			"label": "Go to: " + tab.title(),
			"detail": "repository",
			"run": func() -> void: _tabs.current_tab = index,
		})
		for wt: Dictionary in tab.worktrees():
			if bool(wt["is_main"]) or bool(wt["bare"]):
				continue
			var path: String = String(wt["path"])
			entries.append({
				"label": "Go to: %s · %s" % [tab.title(), String(wt["name"])],
				"detail": "worktree · " + String(wt["branch"]),
				"run": func() -> void:
					_tabs.current_tab = index
					tab.show_worktree(path),
			})
	for entry: Dictionary in _recent_entries():
		entries.append({"label": "Open recent: " + String(entry["label"]), "detail": String(entry["tooltip"]),
			"run": entry["run"]})
	return entries
