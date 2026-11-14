class_name MergeDialog
extends ConfirmationDialog
## Merging a branch, remote branch, tag or commit into the current branch,
## or rebasing the current branch onto it (PLAN §4 Merge with preview).
## Rows: `source ▾ → here` (the source chip picks another branch and checks
## again), badges with what the preview found, the strategy (Merge | Squash
## | Fast-forward | Rebase), the merge commit's message, then Conflicts and
## Commits (a rebase: To replay, then Incoming), which fold and scroll after
## a few rows. The primary button says what will happen. Nothing to merge or
## a failed preview leaves the chips, one line and Close. Rebase checks its
## commits one by one when it is picked.

## Run `strategy` (`merge`, `squash`, `ff`, `rebase`) on `target` (shown as
## `shown`) with `message` (merge only); `shelve` puts local changes on a
## shelf first (those the merge touches; a rebase needs all of them away).
signal start_requested(target: String, shown: String, strategy: String, message: String, shelve: bool)

const THEME_TYPE: StringName = &"MergeDialog"
const BADGE: StringName = &"SummaryBadge"
## The picker's segments in order: `[id, label, icon]`.
const STRATEGIES: Array[Array] = [
	["merge", "Merge", &"GitMerge"],
	["squash", "Squash", &"GitSquash"],
	["ff", "Fast-forward", &"GitFastForward"],
	["rebase", "Rebase", &"GitRebase"],
]
## The primary button when local changes go on a shelf first.
const SHELVE_FIRST: Dictionary[String, String] = {
	"merge": "Shelve changes and merge",
	"squash": "Shelve changes and squash",
	"ff": "Shelve changes and fast-forward",
	"rebase": "Shelve changes and rebase",
}

var session: RepoSession = null:
	set(value):
		if session != null:
			session.merge_preview_ready.disconnect(_on_preview)
			session.rebase_check_ready.disconnect(_on_rebase_check)
			session.job_finished.disconnect(_on_job_finished)
		session = value
		_popover.session = value
		if session != null:
			session.merge_preview_ready.connect(_on_preview)
			session.rebase_check_ready.connect(_on_rebase_check)
			session.job_finished.connect(_on_job_finished)

## What is merged: a full ref name or a commit, and how it is shown.
var _target: String = ""
var _shown: String = ""
var _preview_job: int = -1
## The preview once it arrived (`RepoSession.merge_preview`), else empty.
var _preview: Dictionary = {}
## Why the preview failed, or "".
var _failure: String = ""
var _strategy: String = "merge"
## The rebase check (`RepoSession.rebase_check`) once it arrived, its job
## (-1 until Rebase is picked), and why it failed.
var _rebase: Dictionary = {}
var _rebase_job: int = -1
var _rebase_failure: String = ""

var _box: VBoxContainer = VBoxContainer.new()
var _source_button: Button = Button.new()
var _source_row: HBoxContainer = HBoxContainer.new()
var _source_icon: TextureRect = TextureRect.new()
var _source_label: Label = Label.new()
var _here_label: Label = Label.new()
## The first row, wrapping when it runs out of width: `source ▾ →`, the
## current branch, then the badges (or the spinner while checking).
var _head: HFlowContainer = HFlowContainer.new()
var _from: HBoxContainer = HBoxContainer.new()
var _to: PanelContainer = PanelContainer.new()
var _popover: BranchPopover = BranchPopover.new()
## The badges in `_head`, after the branches.
var _badges: Array[Control] = []
var _checking: HBoxContainer = HBoxContainer.new()
var _spinner: TextureRect = null
var _spin: Tween = null
var _final: HBoxContainer = HBoxContainer.new()
var _final_icon: TextureRect = null
var _final_label: Label = Label.new()
## The line of a final state ("main already has everything in topic").
## A dim line under the first row ("Checked the first 100").
var _note: Label = Label.new()
var _picker: PanelContainer = PanelContainer.new()
var _segments: Dictionary[String, Button] = {}
var _message: TextEdit = TextEdit.new()
var _conflicts: MergeSection = MergeSection.new()
var _commits: MergeSection = MergeSection.new()
## A rebase's incoming commits (`_commits` lists what it replays).
var _incoming: MergeSection = MergeSection.new()


func _ready() -> void:
	get_ok_button().theme_type_variation = &"PrimaryButton"
	FormDialog.align_right(self, get_ok_button())
	confirmed.connect(_start)
	add_child(_box)
	# Row 1: source ▾ → here, then the badges, wrapping as needed.
	var chips: HBoxContainer = _from
	_source_button.theme_type_variation = &"RefChipButton"
	_source_button.tooltip_text = tr("Merge another branch")
	_source_button.pressed.connect(func() -> void: _popover.open_below(_source_button, true))
	_source_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_source_row.add_child(_source_icon)
	_source_row.add_child(_source_label)
	var arrow_down: TextureRect = _icon_rect(&"GuiTreeArrowDown")
	arrow_down.texture = AppTheme.ARROW_DOWN
	arrow_down.modulate.a = 0.6
	_source_row.add_child(arrow_down)
	_source_button.add_child(_source_row)
	_source_row.minimum_size_changed.connect(_size_source)
	chips.add_child(_source_button)
	var arrow: Label = Label.new()
	arrow.text = "→"
	arrow.theme_type_variation = &"DimLabel"
	chips.add_child(arrow)
	_head.add_child(chips)
	_to.theme_type_variation = &"RefChip"
	_to.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var here_row: HBoxContainer = HBoxContainer.new()
	here_row.add_child(_icon_rect(&"GitBranch"))
	here_row.add_child(_here_label)
	_to.add_child(here_row)
	_head.add_child(_to)
	_box.add_child(_head)
	# Checking (in the first row), or the final line under it.
	_checking.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_spinner = _icon_rect(&"Reload")
	_spinner.modulate.a = 0.6
	_checking.add_child(_spinner)
	var checking: Label = Label.new()
	checking.text = tr("Checking…")
	checking.theme_type_variation = &"DimLabel"
	_checking.add_child(checking)
	_head.add_child(_checking)
	_final_icon = _icon_rect(&"StatusSuccess")
	_final.add_child(_final_icon)
	_final_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_final_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_final.add_child(_final_label)
	_box.add_child(_final)
	_note.theme_type_variation = &"DimLabel"
	_box.add_child(_note)
	# Row 3: the strategy.
	_picker.theme_type_variation = &"ViewTabs"
	_picker.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var switch: HBoxContainer = HBoxContainer.new()
	switch.theme_type_variation = &"ViewSwitch"
	var group: ButtonGroup = ButtonGroup.new()
	for entry: Array in STRATEGIES:
		var id: String = entry[0]
		var button: Button = Button.new()
		button.theme_type_variation = &"ViewTab"
		button.toggle_mode = true
		button.button_group = group
		button.text = tr(String(entry[1]))
		button.icon = AppTheme.icon(entry[2])
		button.pressed.connect(func() -> void: set_strategy(id))
		switch.add_child(button)
		_segments[id] = button
	_picker.add_child(switch)
	_box.add_child(_picker)
	# One line until the message has more: the box grows with its text.
	_message.placeholder_text = tr("Merge commit message")
	_message.scroll_fit_content_height = true
	_message.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_message.text_changed.connect(_fit_later)
	AutoScroll.enable(_message)
	_box.add_child(_message)
	_conflicts.folded_changed.connect(_fit_later)
	_box.add_child(_conflicts)
	_commits.folded_changed.connect(_fit_later)
	_box.add_child(_commits)
	_incoming.folded_changed.connect(_fit_later)
	_box.add_child(_incoming)
	_popover.merge_chosen.connect(func(ref: Dictionary) -> void: _load(String(ref["name"]), String(ref["short"])))
	add_child(_popover)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		for entry: Array in STRATEGIES:
			_segments[String(entry[0])].text = tr(String(entry[1]))
		if visible:
			_render()


## Opens the dialog for `target` (a branch, remote branch or tag by full
## name, or a commit), shown as `shown`; it fills in once the preview arrives.
func open(target: String, shown: String = "") -> void:
	_load(target, shown)
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE), 0))
	_fit_later()


## Checks `target` again from the start (opening, or the source chip).
func _load(target: String, shown: String) -> void:
	_target = target
	_shown = shown if not shown.is_empty() else (target.left(7) if target.is_valid_hex_number() else target)
	_preview = {}
	_failure = ""
	_message.text = ""
	_commits.touched = false
	_incoming.touched = false
	_rebase = {}
	_rebase_job = -1
	_rebase_failure = ""
	_preview_job = session.load_merge_preview(target) if session != null else -1
	if _preview_job < 0:
		_failure = tr("This cannot be merged")
	_render()


## The strategy the picker shows (`merge`, `squash`, `ff`, `rebase`).
func strategy() -> String:
	return _strategy


## Picks `id` if it can run now. Returns whether it did.
func set_strategy(id: String) -> bool:
	if not _segments.has(id) or _segments[id].disabled:
		return false
	_strategy = id
	if id == "rebase" and _rebase_job < 0 and _rebase.is_empty():
		_rebase_job = session.load_rebase_check(_target)
		if _rebase_job < 0:
			_rebase_failure = tr("This cannot be rebased")
	_render()
	return true


## Whether segment `id` can be picked, and why not (for tests).
func strategy_enabled(id: String) -> bool:
	return _segments.has(id) and not _segments[id].disabled


func strategy_reason(id: String) -> String:
	return _segments[id].tooltip_text if _segments.has(id) else ""


## The badges' texts in order, or the checking or final line (for tests).
func summary_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _checking.visible:
		out.append(tr("Checking…"))
	elif _final.visible:
		out.append(_final_label.text)
	else:
		for badge: Control in _badges:
			out.append(String(badge.get_meta(&"text", "")))
	return out


## The conflicted files listed (for tests).
func conflict_paths() -> PackedStringArray:
	return _conflicts.row_keys() if _conflicts.visible else PackedStringArray()


## The commits listed, as short hashes (for tests).
func commit_rows() -> PackedStringArray:
	return _commits.row_keys() if _commits.visible else PackedStringArray()


## The dim line under the badges, or "" (for tests).
func note_text() -> String:
	return _note.text if _note.visible else ""


func incoming_section() -> MergeSection:
	return _incoming


func conflicts_section() -> MergeSection:
	return _conflicts


func commits_section() -> MergeSection:
	return _commits


func source_button() -> Button:
	return _source_button


func source_text() -> String:
	return _source_label.text


func branch_popover() -> BranchPopover:
	return _popover


func message_edit() -> TextEdit:
	return _message


func _here() -> String:
	var branch: String = session.current_branch() if session != null else ""
	return branch if not branch.is_empty() else tr("this commit")


func _on_preview(target: String) -> void:
	if not visible or target != _target or not _preview.is_empty():
		return
	_preview = session.merge_preview()
	_message.text = String(_preview.get("message", ""))
	_strategy = "ff" if bool(_preview.get("can_ff", false)) else "merge"
	_render()
	get_ok_button().grab_focus()


func _on_rebase_check(target: String) -> void:
	if not visible or target != _target or not _rebase.is_empty():
		return
	_rebase = session.rebase_check()
	_render()


func _on_job_finished(job: int, _label: String, ok: bool, error: Dictionary) -> void:
	if ok or job < 0 or not visible:
		return
	if job == _preview_job:
		_failure = String(error.get("message", ""))
		if _failure.is_empty():
			_failure = tr("This cannot be merged")
		_render()
	elif job == _rebase_job:
		_rebase_failure = String(error.get("message", ""))
		if _rebase_failure.is_empty():
			_rebase_failure = tr("This cannot be rebased")
		_render()


## Lays the dialog out for the preview and the strategy.
func _render() -> void:
	var into: String = _here()
	var rebasing: bool = _strategy == "rebase"
	title = tr("Rebase %s") % into if rebasing else tr("Merge into %s") % into
	_set_route_tooltip(tr("%s's commits are replayed on %s") % [into, _shown] if rebasing else "")
	_source_label.text = _shown
	_source_icon.texture = AppTheme.icon(_ref_icon(_target))
	_here_label.text = into
	var ok: Button = get_ok_button()
	ok.visible = true
	cancel_button_text = tr("Cancel")
	var checking: bool = _preview.is_empty() and _failure.is_empty()
	var up_to_date: bool = bool(_preview.get("up_to_date", false))
	var final: bool = not _failure.is_empty() or up_to_date
	_checking.visible = checking
	_set_spinning(checking)
	_final.visible = final
	if checking or final:
		_clear_badges()
	_note.visible = false
	_incoming.visible = false
	_picker.visible = not final
	for id: String in _segments:
		_segments[id].disabled = checking
		_segments[id].tooltip_text = ""
	_show_strategy()
	if checking:
		_message.visible = false
		_conflicts.visible = false
		_commits.visible = false
		ok.text = tr("Merge")
		ok.icon = AppTheme.icon(&"GitMerge")
		ok.disabled = true
		ok.tooltip_text = tr("Checking for conflicts…")
		_fit_later()
		return
	if final:
		var failed: bool = not _failure.is_empty()
		_final_icon.texture = AppTheme.tintable_icon(&"StatusWarning" if failed else &"StatusSuccess")
		_final_icon.modulate = get_theme_color(&"error_color" if failed else &"success_color", BADGE)
		_final_label.text = _failure if failed else tr("%s already has everything in %s") % [into, _shown]
		_message.visible = false
		_conflicts.visible = false
		_commits.visible = false
		ok.visible = false
		cancel_button_text = tr("Close")
		_fit_later()
		return
	var p: Dictionary = _preview
	var can_ff: bool = bool(p["can_ff"])
	if not can_ff:
		_segments["ff"].disabled = true
		_segments["ff"].tooltip_text = tr("%s has commits %s doesn't") % [into, _shown]
	var rebase_reason: String = _rebase_reason(p)
	_segments["rebase"].disabled = not rebase_reason.is_empty()
	_segments["rebase"].tooltip_text = rebase_reason
	if _segments[_strategy].disabled:
		_strategy = "merge"
		rebasing = false
		title = tr("Merge into %s") % into
		_set_route_tooltip("")
	_show_strategy()
	if rebasing:
		_render_rebase(p, into)
		return
	var conflicts: Array = p["conflicts"]
	var overlap: PackedStringArray = p["overlap"]
	var count: int = int(p["commit_count"])
	# Badges: what the preview found.
	_clear_badges()
	if _strategy == "ff":
		_add_badge(&"GitFastForward", tr("Fast-forward"), &"accent",
				tr("%s moves to %s") % [into, _shown])
	elif conflicts.is_empty():
		_add_badge(&"StatusSuccess", tr("No conflicts"), &"success")
	else:
		_add_badge(&"GitConflict", tr("Conflicts"), &"error")
	_add_badge(&"FileList", _files(int(p["file_count"])), &"neutral")
	if not overlap.is_empty():
		_add_badge(&"StatusWarning", tr("%d shelved") % overlap.size(), &"warning",
				tr("The merge would overwrite these local changes. They go on a shelf first and come back after a clean merge; if it conflicts, they stay on the shelf until it is finished.")
				+ "\n" + "\n".join(overlap))
	_message.visible = _strategy == "merge"
	# Conflicts, then the commits (folded when there are conflicts).
	var with_conflicts: bool = not conflicts.is_empty() and _strategy != "ff"
	_conflicts.visible = with_conflicts
	if with_conflicts:
		_conflicts.set_title(tr("Conflicts"), conflicts.size())
		_fill_conflicts(conflicts)
	_commits.visible = count > 0
	if count > 0:
		_commits.set_title(tr("Commits"), count)
		_fill_commits(_commits, p["commits"], count)
		if not _commits.touched:
			_commits.set_folded(with_conflicts)
	# The primary button says what will happen.
	match _strategy:
		"merge":
			ok.text = tr("Merge and resolve…") if with_conflicts else tr("Create merge commit")
		"squash":
			ok.text = tr("Squash and resolve…") if with_conflicts else tr("Squash %s") % _commits_text(count)
		"ff":
			ok.text = tr("Fast-forward %s") % into
	if not overlap.is_empty():
		ok.text = tr(String(SHELVE_FIRST[_strategy]))
	ok.icon = AppTheme.icon(_icon_of(_strategy))
	ok.disabled = false
	ok.tooltip_text = ""
	_fit_later()


## Why Rebase cannot be picked for preview `p`, or "".
func _rebase_reason(p: Dictionary) -> String:
	if String(session.current_branch()).is_empty():
		return tr("Check out a branch to rebase it")
	if bool(p.get("can_ff", false)):
		return tr("%s has no commits of its own: fast-forward instead") % _here()
	if not bool(p.get("can_rebase", false)):
		return tr("There is nothing to rebase")
	return ""


## Rebase: what the check found, what it replays and what comes in.
func _render_rebase(p: Dictionary, into: String) -> void:
	var ok: Button = get_ok_button()
	_message.visible = false
	var changes: int = session.change_count()
	_clear_badges()
	var waiting: bool = _rebase.is_empty() and _rebase_failure.is_empty()
	_checking.visible = waiting
	_set_spinning(waiting)
	_final.visible = not _rebase_failure.is_empty()
	var stop: Dictionary = _rebase.get("stop", {})
	if not _rebase_failure.is_empty():
		_final_icon.texture = AppTheme.tintable_icon(&"StatusWarning")
		_final_icon.modulate = get_theme_color(&"error_color", BADGE)
		_final_label.text = _rebase_failure
	elif not waiting:
		if stop.is_empty():
			_add_badge(&"StatusSuccess", tr("No conflicts"), &"success")
		else:
			_add_badge(&"GitConflict", tr("Conflicts"), &"error")
		_add_badge(&"FileList", _files(int(p["file_count"])), &"neutral")
		if changes > 0:
			_add_badge(&"StatusWarning", tr("%d shelved") % changes, &"warning",
					tr("A rebase needs the local changes out of the way. They go on a shelf first and come back after a clean rebase; if it stops on conflicts, they stay on the shelf until it is finished."))
		var pushed: int = int(p.get("own_pushed", 0))
		if pushed > 0:
			_add_badge(&"StatusWarning", tr("Rewrites %d pushed") % pushed, &"warning",
					tr("These commits are already pushed: after the rebase, Sync offers a force push to replace them."))
		var merges: int = int(p.get("own_merges", 0))
		if merges > 0:
			_add_badge(&"GitMerge", tr("1 merge flattened") if merges == 1 else tr("%d merges flattened") % merges,
					&"neutral", tr("The rebase replays the commits without their merges."))
		if bool(_rebase.get("partial", false)):
			_note.text = tr("Checked the first %d") % int(_rebase.get("checked", 0))
			_note.visible = true
	# Where it stops, then what it replays, then what comes in (folded).
	var conflicts: Array = stop.get("conflicts", [])
	_conflicts.visible = not conflicts.is_empty()
	if not conflicts.is_empty():
		_conflicts.set_title(tr("Conflicts"), conflicts.size())
		_fill_conflicts(conflicts)
		var at: Label = Label.new()
		at.text = tr("Stops at %s %s") % [String(stop["oid"]).left(7), String(stop["subject"])]
		at.tooltip_text = at.text
		at.mouse_filter = Control.MOUSE_FILTER_PASS
		at.theme_type_variation = &"DimLabel"
		at.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_conflicts.add_row(at, "")
	var own: int = int(p.get("own_count", 0))
	_commits.visible = own > 0
	if own > 0:
		_commits.set_title(tr("To replay"), own)
		_fill_commits(_commits, p["own_commits"], own)
		if not _commits.touched:
			_commits.set_folded(not conflicts.is_empty())
	var count: int = int(p["commit_count"])
	_incoming.visible = count > 0
	if count > 0:
		_incoming.set_title(tr("Incoming"), count)
		_fill_commits(_incoming, p["commits"], count)
		if not _incoming.touched:
			_incoming.set_folded(true)
	ok.text = tr("Rebase and resolve…") if not conflicts.is_empty() else tr("Rebase %s") % into
	if changes > 0:
		ok.text = tr(String(SHELVE_FIRST["rebase"]))
	ok.icon = AppTheme.icon(&"GitRebase")
	ok.disabled = waiting or not _rebase_failure.is_empty()
	ok.tooltip_text = tr("Checking for conflicts…") if waiting else _rebase_failure
	_fit_later()


## Presses the segment of the strategy, and only it.
func _show_strategy() -> void:
	for id: String in _segments:
		_segments[id].set_pressed_no_signal(id == _strategy)


func _start() -> void:
	if _preview.is_empty() or bool(_preview.get("up_to_date", false)):
		return
	var overlap: PackedStringArray = _preview.get("overlap", PackedStringArray())
	var message: String = _message.text if _strategy == "merge" else ""
	var shelve: bool = session.change_count() > 0 if _strategy == "rebase" else not overlap.is_empty()
	start_requested.emit(_target, _shown, _strategy, message, shelve)


## The preview as it arrived (for RepoOps: the squash's commit subjects).
func preview() -> Dictionary:
	return _preview


func _fill_conflicts(conflicts: Array) -> void:
	_conflicts.clear_rows()
	var color: Color = get_theme_color(FileRowPainter.CODE_COLORS["U"], FileRowPainter.THEME_TYPE)
	for conflict: Dictionary in conflicts:
		var path: String = String(conflict["path"])
		var row: HBoxContainer = HBoxContainer.new()
		var icon: TextureRect = _icon_rect(&"FileConflict")
		icon.modulate = color
		row.add_child(icon)
		var label: Label = Label.new()
		label.text = path
		label.tooltip_text = path
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(label)
		_conflicts.add_row(row, path)


## A row per commit as History's compact rows have it: avatar, subject,
## author and age (dim), then the short hash.
func _fill_commits(section: MergeSection, commits: Array, count: int) -> void:
	section.clear_rows()
	var now: int = int(Time.get_unix_time_from_system())
	var side: float = float(get_theme_constant(&"avatar_size", THEME_TYPE))
	for commit: Dictionary in commits:
		var row: HBoxContainer = HBoxContainer.new()
		var avatar: AvatarView = AvatarView.new(String(commit["author"]), String(commit.get("email", "")), side)
		avatar.session = session
		avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(avatar)
		var subject: Label = Label.new()
		subject.text = String(commit["subject"])
		subject.tooltip_text = subject.text
		subject.mouse_filter = Control.MOUSE_FILTER_PASS
		subject.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		subject.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(subject)
		var who: Label = Label.new()
		who.text = "%s · %s" % [String(commit["author"]), RepoOps.ago(now - int(commit["time"]))]
		who.theme_type_variation = &"DimLabel"
		row.add_child(who)
		var oid: Label = Label.new()
		oid.text = String(commit["oid"]).left(7)
		oid.theme_type_variation = &"DetailsHash"
		row.add_child(oid)
		section.add_row(row, String(commit["oid"]).left(7))
	if count > commits.size():
		var more: Label = Label.new()
		more.text = tr("and %d more") % (count - commits.size())
		more.theme_type_variation = &"DimLabel"
		section.add_row(more, "")


## A tinted pill: `icon` and `text` in the colour of `tone` (`success`,
## `error`, `accent`, `warning`, `neutral`).
func _add_badge(icon: StringName, text: String, tone: StringName, tooltip: String = "") -> void:
	var badge: PanelContainer = PanelContainer.new()
	badge.add_theme_stylebox_override(&"panel", get_theme_stylebox(tone, BADGE))
	badge.set_meta(&"text", text)
	badge.set_meta(&"tone", tone)
	badge.tooltip_text = tooltip
	var color: Color = get_theme_color(StringName(String(tone) + "_color"), BADGE)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", get_theme_constant(&"separation", BADGE))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var side: float = float(get_theme_constant(&"icon_size", BADGE))
	var rect: TextureRect = TextureRect.new()
	rect.texture = AppTheme.tintable_icon(icon)
	rect.modulate = color
	rect.custom_minimum_size = Vector2(side, side)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rect)
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_font_size_override(&"font_size", get_theme_font_size(&"font_size", BADGE))
	row.add_child(label)
	badge.add_child(row)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head.add_child(badge)
	_badges.append(badge)


func _clear_badges() -> void:
	for badge: Control in _badges:
		_head.remove_child(badge)
		badge.queue_free()
	_badges.clear()


## The tooltip of the branches in the first row.
func _set_route_tooltip(text: String) -> void:
	_from.tooltip_text = text
	_to.tooltip_text = text


func _set_spinning(on: bool) -> void:
	if on and _spin == null:
		_spin = _spinner.create_tween().set_loops()
		_spin.tween_property(_spinner, "rotation", TAU, 1.0).from(0.0)
	elif not on and _spin != null:
		_spin.kill()
		_spin = null
		_spinner.rotation = 0.0


## The source chip's size follows its row (icon, name, ▾).
func _size_source() -> void:
	var box: StyleBox = _source_button.get_theme_stylebox(&"normal")
	var inner: Vector2 = _source_row.get_combined_minimum_size()
	_source_button.custom_minimum_size = inner + box.get_minimum_size()
	_source_row.position = Vector2(box.get_margin(SIDE_LEFT), box.get_margin(SIDE_TOP))
	_source_row.size = inner


func _fit_later() -> void:
	_fit.call_deferred()


## Shrinks the dialog to its rows at its width, and centres it again.
func _fit() -> void:
	if not visible:
		return
	size = Vector2i(maxi(size.x, get_theme_constant(&"width", THEME_TYPE)), 0)
	move_to_center()


func _apply_theme() -> void:
	_box.add_theme_constant_override(&"separation", get_theme_constant(&"separation", THEME_TYPE))
	var gap: int = get_theme_constant(&"gap", BADGE)
	_head.add_theme_constant_override(&"h_separation", gap)
	_head.add_theme_constant_override(&"v_separation", gap)
	var chip_size: int = get_theme_font_size(&"chip_font_size", THEME_TYPE)
	for label: Label in [_source_label, _here_label]:
		label.add_theme_font_size_override(&"font_size", chip_size)
	var rows: int = get_theme_constant(&"list_rows", THEME_TYPE)
	var row_height: int = get_theme_constant(&"row_height", THEME_TYPE)
	for section: MergeSection in [_conflicts, _commits, _incoming]:
		section.max_height = float(rows * row_height)
		section.row_height = float(row_height)
	_size_source()


func _icon_rect(icon: StringName) -> TextureRect:
	var rect: TextureRect = TextureRect.new()
	var side: float = 16.0
	rect.texture = AppTheme.icon(icon)
	rect.custom_minimum_size = Vector2(side, side)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rect.pivot_offset = Vector2(side, side) / 2.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


static func _icon_of(id: String) -> StringName:
	for entry: Array in STRATEGIES:
		if String(entry[0]) == id:
			return entry[2]
	return &"GitMerge"


## The icon of a merge target: a tag, a remote branch, a commit or a branch.
static func _ref_icon(target: String) -> StringName:
	if target.begins_with("refs/tags/"):
		return &"GitTag"
	if target.begins_with("refs/remotes/"):
		return &"GitRemote"
	if target.is_valid_hex_number() and target.length() >= 7:
		return &"GitCommit"
	return &"GitBranch"


static func _clear(parent: Node) -> void:
	for child: Node in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


## "1 file", "3 files".
func _files(n: int) -> String:
	return tr("1 file") if n == 1 else tr("%d files") % n


## "1 commit", "3 commits".
func _commits_text(n: int) -> String:
	return tr("1 commit") if n == 1 else tr("%d commits") % n
