class_name WorktreeView
extends Control
## One worktree of a repository tab (PLAN §4): the Branch and Sync buttons,
## the banner of an operation in progress, and the Changes or History panes
## with a switch at the top of their left column. Owns the worktree's
## RepoSession and the RepoOps that run its operations, builds the context
## menus of branches, ref labels, commits and worktree chips from the action
## registry, and dims its panes while a job changes its files.

## The title, branch or state may have changed.
signal state_changed()
## Something the user should read (from the operations).
signal notice(title: String, message: String)
## A worktree should show (a branch checked out there, a new task).
signal worktree_open_requested(path: String)
## A worktree is about to be removed: its view should close.
signal worktree_close_requested(path: String)
## The user confirmed deleting a worktree (see `RepoOps.delete_requested`).
signal worktree_delete_requested(path: String, force: bool, branch: String)

enum View { HISTORY, CHANGES, SHELVES }

## Context menu entries per ref type; &"" is a separator.
const REF_MENUS: Dictionary[String, Array] = {
	"branch": [&"branch.checkout", &"branch.merge", &"", &"branch.new", &"tag.new", &"",
		&"branch.rename", &"branch.set_upstream", &"branch.delete"],
	"remote": [&"branch.checkout", &"branch.merge", &"branch.new", &"tag.new"],
	"tag": [&"commit.checkout", &"branch.merge", &"branch.new", &"", &"tag.push", &"tag.delete"],
	"worktree": [&"worktree.open_in_editor", &"worktree.open_terminal", &"worktree.show_in_file_manager",
		&"worktree.copy_path", &"", &"worktree.lock", &"worktree.unlock", &"", &"worktree.remove"],
}
## A ref label in the graph offers fewer actions than the branch list.
const LABEL_MENUS: Dictionary[String, Array] = {
	"branch": [&"branch.checkout", &"branch.merge", &"", &"branch.delete"],
	"remote": [&"branch.checkout", &"branch.merge"],
	"tag": [&"branch.merge", &"", &"tag.push", &"tag.delete"],
}
const COMMIT_MENU: Array[StringName] = [&"commit.checkout", &"branch.new", &"tag.new", &"",
	&"commit.cherry_pick", &"commit.merge", &"", &"commit.copy_hash"]
const SYNC_MENU: Array[StringName] = [&"sync.fetch", &"sync.pull_merge", &"sync.pull_rebase", &"sync.push",
	&"", &"sync.force_push"]
## Jobs that change the worktree's files: its panes dim while they run.
const BLOCKING: Dictionary[String, String] = {
	"checkout": "Switching branches",
	"shelve": "Shelving",
	"restore shelf": "Restoring the shelf",
	"restore shelf file": "Restoring the shelved file",
	"pull": "Pulling",
	"cherry-pick": "Cherry-picking",
	"abort": "Aborting",
	"merge": "Merging",
	"continue": "Continuing",
	"skip": "Skipping the commit",
	"undo commit": "Undoing the commit",
}
## What the banner says an operation does.
const DOING: Dictionary[String, String] = {
	"merge": "Merging", "rebase": "Rebasing", "cherry_pick": "Cherry-picking",
	"revert": "Reverting", "bisect": "Bisecting", "am": "Applying patches",
}
## How long a blocking job runs before the panes dim.
const OVERLAY_DELAY: float = 0.3
## What the Sync button says and shows per `RepoOps.sync_state()`.
const SYNC_ICONS: Dictionary[String, StringName] = {
	"publish": &"GitPush", "push": &"GitPush", "pull": &"GitPull", "sync": &"Reload", "fetch": &"GitFetch",
}

var session: RepoSession = null
var view: View = View.HISTORY
## Shows job progress and results; set before `setup`.
var feedback: Feedback = null

var _ops: RepoOps = RepoOps.new()
var _menu: PopupMenu = PopupMenu.new()
var _menu_actions: Array[StringName] = []
## What the open context menu is about; actions see it through `ref_target`
## and `commit_target` while the menu builds and runs.
var _menu_ref: Dictionary = {}
var _menu_commit: Dictionary = {}
var _menu_active: bool = false
var _sync_menu: PopupMenu = PopupMenu.new()
var _sync_ids: Array[StringName] = []
var _popover: BranchPopover = BranchPopover.new()
var _switch: HBoxContainer = HBoxContainer.new()
var _history_button: Button = Button.new()
var _changes_button: Button = Button.new()
var _shelves_button: Button = Button.new()
var _shelves_badge: CountBadge = CountBadge.new()
## The number of changed files on the Changes button.
var _changes_badge: CountBadge = CountBadge.new()
## The blocking job the overlay shows, or -1.
var _overlay_job: int = -1
var _overlay_doing: String = ""
var _overlay_detail: String = ""
## One left-column width shared by Changes, History and Shelves.
var _sidebar_width: int = 0

@onready var _layout: Control = %Layout
@onready var _history: HistoryView = %History
@onready var _changes: ChangesView = %Changes
@onready var _branch_button: BigButton = %BranchButton
@onready var _sync_button: BigButton = %SyncButton
@onready var _banner: Control = %Banner
@onready var _banner_icon: TextureRect = %BannerIcon
@onready var _banner_label: Label = %BannerLabel
## The banner's text: what runs, the rebase step as a pill, the commit's
## subject (dimmed) and what is left; laid out by hand so the subject shortens
## first, then what runs.
var _banner_text: Control = Control.new()
var _banner_step: Label = Label.new()
var _banner_subject: Label = Label.new()
var _banner_status: Label = Label.new()
@onready var _abort_button: Button = %AbortButton
var _continue_button: Button = Button.new()
var _skip_button: Button = Button.new()
var _resolver_button: Button = Button.new()
@onready var _overlay: Control = %Overlay
@onready var _overlay_label: Label = %OverlayLabel
@onready var _overlay_progress: ProgressBar = %OverlayProgress
@onready var _overlay_cancel: Button = %OverlayCancel
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel


func _ready() -> void:
	_build_banner_text()
	_switch.theme_type_variation = &"ViewSwitch"
	var group: ButtonGroup = ButtonGroup.new()
	for entry: Array in [[_changes_button, "Changes", &"FileList", View.CHANGES, &"view.changes"],
			[_history_button, "History", &"History", View.HISTORY, &"view.history"],
			[_shelves_button, "Shelves", &"GitShelf", View.SHELVES, &"view.shelves"]]:
		var button: Button = entry[0]
		button.text = entry[1]
		button.icon = AppTheme.icon(entry[2])
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.button_group = group
		button.theme_type_variation = &"SegmentButton"
		var action_id: StringName = entry[4]
		button.pressed.connect(func() -> void: Actions.run_action(action_id, button))
		button.tooltip_text = Actions.tooltip(entry[4])
		_switch.add_child(button)
	_changes_button.add_child(_changes_badge)
	_shelves_button.add_child(_shelves_badge)
	_shelves_button.hide()
	add_child(_ops)
	_ops.notice.connect(func(title_text: String, message: String) -> void: notice.emit(title_text, message))
	_ops.open_requested.connect(func(path: String) -> void: worktree_open_requested.emit(path))
	_ops.close_requested.connect(func(path: String) -> void: worktree_close_requested.emit(path))
	_ops.delete_requested.connect(func(path: String, force: bool, branch: String) -> void:
		worktree_delete_requested.emit(path, force, branch))
	add_child(_menu)
	_menu.id_pressed.connect(_on_menu_id)
	_menu.popup_hide.connect(func() -> void:
		if _menu.get_parent() == _popover:
			_menu.reparent(self))
	add_child(_sync_menu)
	_sync_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_sync_ids[id], _sync_button))
	add_child(_popover)
	_popover.branch_chosen.connect(_on_branch_chosen)
	_popover.menu_requested.connect(func(ref: Dictionary, at: Vector2) -> void:
		_menu.reparent(_popover)
		show_ref_menu.call_deferred(ref, at))
	_popover.new_branch_requested.connect(func() -> void: Actions.run_action(&"branch.new", _branch_button))
	_history.commit_menu_requested.connect(_on_commit_menu)
	_history.label_menu_requested.connect(_on_label_menu)
	_branch_button.icon = AppTheme.icon(&"GitBranch")
	_branch_button.pressed.connect(open_branches)
	_branch_button.menu_requested.connect(open_branches)
	_sync_button.pressed.connect(func() -> void: Actions.run_action(&"sync.sync", _sync_button))
	_sync_button.menu_requested.connect(_open_sync_menu)
	_abort_button.icon = Actions.icon(&"operation.abort")
	_abort_button.theme_type_variation = &"DangerTextButton"
	_abort_button.pressed.connect(func() -> void: Actions.run_action(&"operation.abort", _abort_button))
	for entry: Array in [[_resolver_button, "Open resolver", &"operation.open_resolver"],
			[_skip_button, "Skip", &"operation.skip"], [_continue_button, "Continue", &"operation.continue"]]:
		var button: Button = entry[0]
		var id: StringName = entry[2]
		button.text = entry[1]
		button.icon = Actions.icon(id)
		button.pressed.connect(func() -> void: Actions.run_action(id, button))
		_abort_button.add_sibling(button)
		_abort_button.get_parent().move_child(button, _abort_button.get_index())
	_continue_button.theme_type_variation = &"PrimaryButton"
	_popover.merge_chosen.connect(func(ref: Dictionary) -> void:
		_ops.merge_into_current(String(ref["name"]), String(ref["short"])))
	_ops.changes_requested.connect(func(conflicts: bool) -> void:
		show_view(View.CHANGES)
		if conflicts:
			_changes.open_first_conflict())
	_ops.message_suggested.connect(func(summary: String, body: String) -> void:
		_changes.commit_box().suggest_message(summary, body))
	_overlay_cancel.pressed.connect(func() -> void:
		if _overlay_job >= 0:
			session.cancel_job(_overlay_job))
	var panes: Array[SplitContainer] = [_history, _changes, _history.details(), _history.details().files_split(),
			_changes.shelf_files_split()]
	for pane: SplitContainer in panes:
		pane.drag_ended.connect(_on_split_dragged.bind(pane))
	show_view(View.HISTORY)


## Takes ownership of `value` (adds it as a child) and shows its worktree.
func setup(value: RepoSession) -> void:
	session = value
	if session.get_parent() == null:
		add_child(session)
	_history.session = session
	_changes.session = session
	_changes.feedback = feedback
	_changes.ops = _ops
	_ops.session = session
	_ops.feedback = feedback
	_popover.session = session
	for sig: Signal in [session.opened, session.badge_changed, session.status_changed, session.refs_changed,
			session.worktrees_changed, session.operation_changed, session.stashes_changed]:
		sig.connect(_on_state)
	# Resolved files are counted after the status that staged them; Open
	# resolver hides while a conflict is shown.
	session.selection_changed.connect(_update_banner)
	session.diff_changed.connect(_update_banner)
	session.open_failed.connect(_on_open_failed)
	session.missing.connect(_on_missing)
	session.job_started.connect(_on_job_started)
	session.job_progress.connect(_on_job_progress)
	session.job_finished.connect(func(job: int, _label: String, _ok: bool, _error: Dictionary) -> void:
		_on_job_ended(job))
	session.job_cancelled.connect(func(job: int, _label: String) -> void: _on_job_ended(job))
	session.opened.connect(_restore_widths)
	_restore_widths()
	_on_state()
	var error: Dictionary = session.open_error()
	if not error.is_empty():
		_on_open_failed(error)


func repo_path() -> String:
	return session.repo_path() if session != null else ""


## The worktree's folder (the session's toplevel once known).
func worktree_path() -> String:
	if session == null:
		return ""
	var top: String = session.toplevel()
	return top if not top.is_empty() else session.repo_path()


func history() -> HistoryView:
	return _history


func changes() -> ChangesView:
	return _changes


func ops() -> RepoOps:
	return _ops


func branch_button() -> BigButton:
	return _branch_button


func sync_button() -> BigButton:
	return _sync_button


## The number of changes on the Changes button.
func changes_badge() -> CountBadge:
	return _changes_badge


func shelves_button() -> Button:
	return _shelves_button


func branch_popover() -> BranchPopover:
	return _popover


func banner() -> Control:
	return _banner


func overlay() -> Control:
	return _overlay


func has_error() -> bool:
	return _error_panel.visible


## Opens the branch list under the Branch button.
func open_branches() -> void:
	if session != null and session.is_ready():
		_popover.open_below(_branch_button)


## Opens the branch list to pick a branch to merge into the current one.
func open_merge_picker() -> void:
	if session != null and session.is_ready():
		_popover.open_below(_branch_button, true)


## The banner's Continue: the commit box commits a merge or cherry-pick
## (with its message); anything else continues as git does.
func continue_operation() -> void:
	var mode: String = session.commit_mode()
	var box: CommitBox = _changes.commit_box()
	if mode in ["merge", "cherry_pick"] and box.can_commit():
		box.commit(Actions.origin())
		return
	_ops.continue_operation(box.summary(), box.body())


## Shows the Changes view at the first unresolved conflict.
func open_resolver() -> void:
	show_view(View.CHANGES)
	_changes.open_first_conflict()


func continue_button() -> Button:
	return _continue_button


func skip_button() -> Button:
	return _skip_button


func resolver_button() -> Button:
	return _resolver_button


func banner_text() -> String:
	if not _banner.visible:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for label: Label in [_banner_label, _banner_step, _banner_subject, _banner_status]:
		if label.visible and not label.text.is_empty():
			parts.append(label.text)
	return " ".join(parts)


func _build_banner_text() -> void:
	_banner_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_banner_text.clip_contents = true
	_banner_text.mouse_filter = Control.MOUSE_FILTER_PASS
	_banner_label.add_sibling(_banner_text)
	_banner_label.reparent(_banner_text)
	_banner_step.theme_type_variation = &"StepPill"
	_banner_step.tooltip_text = "Commit being applied, of all the commits to apply"
	_banner_step.mouse_filter = Control.MOUSE_FILTER_PASS
	_banner_subject.theme_type_variation = &"DimLabel"
	_banner_subject.mouse_filter = Control.MOUSE_FILTER_PASS
	for label: Label in [_banner_label, _banner_subject]:
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.clip_text = true
	for label: Label in [_banner_step, _banner_subject, _banner_status]:
		_banner_text.add_child(label)
	_banner_text.resized.connect(_place_banner_text)


## Places the banner's labels in a row: the subject gives way first, then
## what runs; the step and what is left keep their width.
func _place_banner_text() -> void:
	var labels: Array[Label] = [_banner_label, _banner_step, _banner_subject, _banner_status]
	var widths: Array[float] = []
	var height: float = 0.0
	for label: Label in labels:
		var shown: bool = label.visible and not label.text.is_empty()
		var font: Font = label.get_theme_font(&"font")
		var text_width: float = font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				label.get_theme_font_size(&"font_size")).x
		widths.append(ceilf(text_width + label.get_theme_stylebox(&"normal").get_minimum_size().x) if shown else 0.0)
		height = maxf(height, label.get_combined_minimum_size().y)
	var gap: float = float(_banner_label.get_parent().get_parent().get_theme_constant(&"separation", &"HBoxContainer"))
	var used: float = 0.0
	for width: float in widths:
		used += width + (gap if width > 0.0 else 0.0)
	var excess: float = maxf(0.0, used - gap - _banner_text.size.x)
	for i: int in [2, 0]:
		var cut: float = minf(excess, widths[i])
		widths[i] -= cut
		excess -= cut
	_banner_text.custom_minimum_size.y = height
	var x: float = 0.0
	for i: int in labels.size():
		var label_height: float = labels[i].get_combined_minimum_size().y
		labels[i].position = Vector2(x, (maxf(height, _banner_text.size.y) - label_height) / 2.0)
		labels[i].size = Vector2(widths[i], label_height)
		if widths[i] > 0.0:
			x += widths[i] + gap


# --- Context menus --------------------------------------------------------------

## The ref the user is acting on: the open context menu's, or empty.
func ref_target() -> Dictionary:
	return _menu_ref if _menu_active else {}


## The commit the user is acting on (`{hash, subject}`): the context menu's,
## or the history's cursor while the history shows.
func commit_target() -> Dictionary:
	if _menu_active:
		return _menu_commit
	return _history.selected_commit() if view == View.HISTORY else {}


## Shows the menu of `ref` (a branch, remote branch, tag or worktree) at a
## screen position.
func show_ref_menu(ref: Dictionary, at_position: Vector2, menus: Dictionary = REF_MENUS) -> void:
	_menu_ref = ref
	_menu_commit = {}
	show_menu(menus.get(String(ref["type"]), []), at_position)


## Shows a context menu of the enabled actions among `ids` at a screen position.
func show_menu(ids: Array, at_position: Vector2) -> void:
	_menu.clear()
	_menu_actions.clear()
	_menu_active = true
	for id: StringName in ids:
		if id == &"":
			if _menu.item_count > 0 and not _menu.is_item_separator(_menu.item_count - 1):
				_menu.add_separator()
		elif Actions.is_enabled(id):
			_menu.add_icon_item(Actions.icon(id), Actions.get_action(id).label, _menu_actions.size())
			_menu_actions.append(id)
	_menu_active = false
	while _menu.item_count > 0 and _menu.is_item_separator(_menu.item_count - 1):
		_menu.remove_item(_menu.item_count - 1)
	if _menu_actions.is_empty():
		return
	_menu.position = Vector2i(at_position)
	_menu.reset_size()
	_menu.popup()


func close_menu() -> void:
	_menu.hide()


func context_menu() -> PopupMenu:
	return _menu


## Labels in the open (or last) context menu, for tests.
func menu_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in _menu.item_count:
		if not _menu.is_item_separator(i):
			out.append(_menu.get_item_text(i))
	return out


## Runs the context menu entry labelled `label` (for tests).
func press_menu(label: String) -> bool:
	for i: int in _menu.item_count:
		if _menu.get_item_text(i) == label:
			_menu.hide()
			_on_menu_id(_menu.get_item_id(i))
			return true
	return false


func _on_menu_id(id: int) -> void:
	_menu_active = true
	Actions.run_action(_menu_actions[id])
	_menu_active = false


func _on_commit_menu(at_position: Vector2) -> void:
	_menu_ref = {}
	_menu_commit = _history.selected_commit()
	show_menu(COMMIT_MENU, at_position)


func _on_label_menu(label: Dictionary, at_position: Vector2) -> void:
	var kind: String = String(label["kind"])
	var ref: Dictionary = {}
	for candidate: Dictionary in session.branch_refs():
		if String(candidate["name"]) == String(label["name"]):
			ref = {"type": "branch" if kind == "branch" else "remote", "name": String(candidate["name"]),
				"short": String(candidate["short_name"]), "commit": String(candidate["commit"]),
				"is_head": bool(candidate["is_head"]), "upstream": String(candidate["upstream"]),
				"worktree": String(candidate["worktree"])}
	if kind == "tag":
		for tag: Dictionary in session.tags():
			if String(tag["name"]) == String(label["short"]):
				ref = {"type": "tag", "name": String(label["name"]), "short": String(tag["name"]),
					"commit": String(tag["commit"]), "is_head": false, "upstream": ""}
	if ref.is_empty():
		_on_commit_menu(at_position)
		return
	show_ref_menu(ref, at_position, LABEL_MENUS)


## A branch from the list: switch to it, or show the worktree that has it.
func _on_branch_chosen(ref: Dictionary) -> void:
	var worktree: String = String(ref.get("worktree", ""))
	if not worktree.is_empty():
		worktree_open_requested.emit(worktree)
	elif String(ref["type"]) == "remote":
		_ops.checkout_remote(String(ref["name"]))
	elif not bool(ref["is_head"]):
		_ops.checkout_branch(String(ref["short"]))


func _open_sync_menu() -> void:
	_sync_menu.clear()
	_sync_ids.clear()
	for id: StringName in SYNC_MENU:
		if id == &"":
			_sync_menu.add_separator()
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		_sync_menu.add_icon_item(Actions.icon(id), action.label, _sync_ids.size())
		_sync_menu.set_item_disabled(_sync_menu.item_count - 1, not action.is_enabled())
		_sync_ids.append(id)
	var rect: Rect2 = _sync_button.get_global_rect()
	_sync_menu.position = Vector2i(get_window().position) + Vector2i((rect.position + Vector2(0.0, rect.size.y)) \
			* get_window().content_scale_factor)
	_sync_menu.reset_size()
	_sync_menu.popup()


# --- Views ----------------------------------------------------------------------

## Switches the panes and focuses them (the changes view focuses its files).
func show_view(which: View) -> void:
	if which == View.SHELVES and (session == null or session.shelves().is_empty()):
		which = View.CHANGES
	view = which
	_history.visible = which == View.HISTORY
	_changes.visible = which != View.HISTORY
	_changes.show_shelves_view(which == View.SHELVES)
	_history_button.set_pressed_no_signal(which == View.HISTORY)
	_changes_button.set_pressed_no_signal(which == View.CHANGES)
	_shelves_button.set_pressed_no_signal(which == View.SHELVES)
	var slot: Container = _history.switch_slot() if which == View.HISTORY else _changes.switch_slot()
	if _switch.get_parent() != slot:
		if _switch.get_parent() != null:
			_switch.get_parent().remove_child(_switch)
		slot.add_child(_switch)
	if _sidebar_width > 0:
		_set_sidebar_width(_sidebar_width)
	if session != null:
		_update_banner()
	focus_view()


func focus_view() -> void:
	if not is_visible_in_tree():
		return
	if view != View.HISTORY:
		_changes.focus_files()
	else:
		_history.commit_list().grab_focus()


## The shared left-pane width, and the commit details' height and
## files width, are saved per repository.
func _on_split_dragged(pane: SplitContainer) -> void:
	if pane == _history or pane == _changes:
		_set_sidebar_width(pane.split_offset)
	Core.set_repo_ui_state(_repo_key(), _split_key(pane), pane.split_offset)


func _set_sidebar_width(width: int) -> void:
	_sidebar_width = width
	_history.split_offset = width
	_changes.split_offset = width


func _split_key(pane: SplitContainer) -> String:
	if pane == _changes.shelf_files_split():
		return "shelves_files_width"
	if pane == _history or pane == _changes:
		return "sidebar_width"
	if pane == _history.details():
		return "details_height"
	return "details_files_width"


## Saved sizes, else the theme's defaults (a split's offset is the size of
## its first part).
func _restore_widths() -> void:
	var saved: Dictionary = Core.repo_ui_state(_repo_key())
	var default: int = get_theme_constant(&"default_left_width", &"Panes")
	# Reuse an existing width when migrating from separate per-view settings.
	_set_sidebar_width(int(saved.get("sidebar_width", saved.get("history_width",
			saved.get("changes_width", saved.get("shelves_width", default))))))
	_changes.shelf_files_split().split_offset = int(saved.get("shelves_files_width", get_theme_constant(&"files_width", &"ShelfView")))
	var details: CommitDetails = _history.details()
	details.split_offset = int(saved.get("details_height",
			details.get_theme_constant(&"details_height", CommitDetails.THEME_TYPE)))
	details.files_split().split_offset = int(saved.get("details_files_width",
			details.get_theme_constant(&"files_width", CommitDetails.THEME_TYPE)))


## Per-repository state is saved under the main worktree's path.
func _repo_key() -> String:
	var main: String = session.main_worktree() if session != null else ""
	return main if not main.is_empty() else worktree_path()


# --- State ----------------------------------------------------------------------

func _on_state() -> void:
	if session == null or not is_node_ready():
		return
	_update_header()
	_update_banner()
	_changes_badge.count = int(session.badge().get("changed", 0))
	_shelves_badge.count = session.shelves().size()
	_shelves_button.visible = _shelves_badge.count > 0
	if view == View.SHELVES and _shelves_badge.count == 0:
		show_view(View.CHANGES)
	state_changed.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_on_state()
		if _overlay_job >= 0:
			_update_overlay()


func _update_header() -> void:
	var branch: String = session.current_branch()
	var head: String = String(session.status().get("oid", ""))
	if branch.is_empty():
		branch = tr("Detached at %s") % head.left(7) if not head.is_empty() else tr("No branch yet")
	_branch_button.show_state(branch, AppTheme.icon(&"GitBranch"), session.is_ready())
	_branch_button.tooltip_text = Actions.tooltip(&"branch.switch")
	var state: String = _ops.sync_state()
	var badge: Dictionary = session.badge()
	var ahead: int = int(badge.get("ahead", 0))
	var behind: int = int(badge.get("behind", 0))
	var caption: String = {
		"publish": tr("Publish branch"),
		"push": tr("Push ↑%d") % ahead,
		"pull": tr("Pull ↓%d") % behind,
		"sync": tr("Sync ↓%d ↑%d") % [behind, ahead],
		"fetch": tr("Fetch"),
	}[state]
	_sync_button.show_state(caption, AppTheme.icon(SYNC_ICONS[state]), session.is_ready() and session.can_fetch())
	var tooltip: String = {
		"publish": tr("Push %s and set its upstream") % session.current_branch(),
		"push": tr("Push your commits to %s") % session.default_remote(),
		"pull": tr("Pull the new commits from %s") % session.default_remote(),
		"sync": tr("Pull the new commits, then push yours"),
		"fetch": tr("Fetch from %s") % session.default_remote(),
	}[state]
	if feedback != null:
		var seconds: int = feedback.seconds_since_fetch(session.repo_path())
		if seconds >= 0:
			tooltip += "\n" + tr("Fetched %s") % _ago(seconds)
	if not session.can_fetch() and session.is_ready():
		tooltip = tr("This repository has no remote. Add one with Repository → Remotes…")
	_sync_button.tooltip_text = tooltip


## "Merging feature/login into main · 2 files to resolve", "Cherry-picking
## abc1234 Fix it", "Rebasing topic onto main (2 / 5) Fix it", with the
## subject dimmed and the step as a pill. Red while
## conflicts are left, green ("ready to commit") once all are resolved.
func _update_banner() -> void:
	var operation: String = session.operation()
	_banner.visible = not operation.is_empty()
	if operation.is_empty():
		return
	var info: Dictionary = session.operation_info()
	var doing: String = tr(DOING.get(operation, operation.capitalize()))
	var head: String = String(info.get("head_name", ""))
	var other: String = String(info.get("other_name", ""))
	var oid: String = String(info.get("other_oid", ""))
	var text: String = doing
	match operation:
		"merge":
			var merged: String = other if not other.is_empty() else oid.left(7)
			text = tr("Merging %s into %s") % [merged, head] if not head.is_empty() else tr("Merging %s") % merged
		"cherry_pick":
			text = tr("Cherry-picking %s") % oid.left(7)
		"revert":
			text = tr("Reverting %s") % oid.left(7)
		"rebase":
			text = tr("Rebasing %s onto %s") % [head if not head.is_empty() else "HEAD", _onto_name(oid)]
	var steps: int = int(info.get("steps", 0)) if operation == "rebase" else 0
	_banner_step.visible = steps > 0
	_banner_step.text = "%d / %d" % [int(info.get("step", 0)), steps] if steps > 0 else ""
	var subject: String = ""
	if operation in ["cherry_pick", "revert"]:
		subject = other
	elif operation == "rebase":
		subject = String(info.get("message", "")).strip_edges().get_slice("\n", 0)
	_banner_subject.text = subject
	_banner_subject.tooltip_text = subject
	var left: int = int(info.get("conflicts", 0))
	var resolved: int = int(info.get("resolved", 0))
	var mode: String = String(info.get("commit_mode", ""))
	var all_resolved: bool = left == 0 and resolved > 0
	var status: String = ""
	if left > 0:
		status = tr("· 1 file to resolve") if left == 1 else tr("· %d files to resolve") % left
	elif all_resolved:
		status = tr("· ready to commit") if mode in ["merge", "cherry_pick"] else tr("· ready to continue")
	_banner_label.text = text
	_banner_label.tooltip_text = text
	_banner_status.text = status
	_place_banner_text.call_deferred()
	_banner.theme_type_variation = &"OperationBannerReady" if all_resolved else &"OperationBanner"
	_banner_icon.texture = AppTheme.tintable_icon(&"StatusSuccess" if all_resolved else &"GitConflict")
	_banner_icon.modulate = _banner.get_theme_color(&"icon_color", _banner.theme_type_variation)
	_skip_button.visible = operation == "rebase"
	# Not while the conflict is already open in the Changes view.
	_resolver_button.visible = left > 0 and not (view == View.CHANGES and _changes.is_conflict_shown())
	# A merge or cherry-pick is committed with the commit box: the banner
	# offers it only where that box is not shown.
	var box_commits: bool = mode in ["merge", "cherry_pick"] and view == View.CHANGES
	_continue_button.visible = operation in ["merge", "cherry_pick", "revert", "rebase", "am"] and not box_commits
	var commit_text: String = {"merge": tr("Commit merge"), "revert": tr("Commit revert")}.get(operation, tr("Commit cherry-pick"))
	_continue_button.text = commit_text if mode in ["merge", "cherry_pick"] else tr("Continue")
	_continue_button.icon = AppTheme.icon(&"GitMerge") if mode == "merge" else Actions.icon(&"operation.continue")
	_continue_button.disabled = not Actions.is_enabled(&"operation.continue")
	_continue_button.tooltip_text = Actions.tooltip(&"operation.continue")


## A branch at `oid`, else its short hash.
func _onto_name(oid: String) -> String:
	for ref: Dictionary in session.branch_refs():
		if String(ref["commit"]) == oid and String(ref["kind"]) == "branch":
			return String(ref["short_name"])
	return oid.left(7)


static func _ago(seconds: int) -> String:
	if seconds < 60:
		return TranslationServer.translate("just now")
	if seconds < 3600:
		return TranslationServer.translate("%d min ago") % floori(seconds / 60.0)
	return TranslationServer.translate("%d h ago") % floori(seconds / 3600.0)


# --- Blocking jobs --------------------------------------------------------------

func _on_job_started(job: int, label: String) -> void:
	if not BLOCKING.has(label):
		return
	_overlay_job = job
	_overlay_doing = BLOCKING[label]
	_overlay_detail = ""
	_update_overlay()
	_overlay_progress.indeterminate = true
	get_tree().create_timer(OVERLAY_DELAY).timeout.connect(func() -> void:
		if _overlay_job == job:
			_overlay.show())


func _on_job_progress(job: int, label: String, percent: int, text: String) -> void:
	if job != _overlay_job:
		return
	_overlay_doing = BLOCKING.get(label, label.capitalize())
	_overlay_detail = text
	_update_overlay()
	_overlay_progress.indeterminate = percent < 0
	_overlay_progress.value = maxf(0.0, float(percent))


func _update_overlay() -> void:
	_overlay_label.text = tr(_overlay_doing) + "…" + ("  " + _overlay_detail if not _overlay_detail.is_empty() else "")


func _on_job_ended(job: int) -> void:
	if job == _overlay_job:
		_overlay_job = -1
		_overlay.hide()


# --- Errors ---------------------------------------------------------------------

func _on_missing() -> void:
	_layout.hide()
	_error_panel.show()
	_error_label.text = tr("%s\n\nThis worktree's folder no longer exists.") % worktree_path()
	state_changed.emit()


func _on_open_failed(error: Dictionary) -> void:
	_layout.hide()
	_error_panel.show()
	_error_label.text = "%s\n%s\n\n%s" % [
		session.repo_path(),
		tr(String(error.get("title", ""))),
		tr(String(error.get("message", ""))),
	]
	state_changed.emit()
