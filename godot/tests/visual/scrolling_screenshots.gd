extends Node
## Scrolling, in numbered shots with any open tooltip drawn in: a worktree
## chip's tooltip, closed when the strip scrolls under the resting mouse (no
## new one while it rests), back once the mouse moves and rests, closed by
## what middle-click autoscroll does as it starts and by the wheel;
## middle-click autoscroll in the commit description, the hook output,
## History's commit message and the Markdown preview; K bringing History's and
## Changes' selected rows back, and K typing in the search field; then the
## light theme. Each shot prints whether a tooltip is open and what it says.
## Only tooltips that do not depend on where the mouse is show here (a list
## row's reads the OS cursor, far from the off-screen window). Pass --repo=<the repository of
## tests/visual/scrolling_prep.sh> --out=<directory>, with GITBELLO_CONFIG set
## to a scratch config, windowed (it saves the Markdown mode; read-only on
## the repository). While it autoscrolls the speed follows the OS cursor,
## which is far from the off-screen window: those shots scroll at full speed.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
## Frames that cover a tooltip's delay and more.
const REST_FRAMES: int = 90

var _out: String = ""
var _step: int = 1
var _main: Main = null
var _mouse: Vector2 = Vector2.ZERO


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("scrolling_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 60):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var list: ChangeList = changes.list()
	list.select_only(0)
	await _settle(30)
	get_viewport().notify_mouse_entered()
	var auto: AutoScroll = AutoScroll.of(get_viewport())

	# #26: a tooltip closes when what is under it scrolls (Godot alone closes
	# it only on a button press) and shows again once the mouse moves and rests.
	var strip: WorktreeStrip = page.strip()
	var strip_row: ScrollRow = strip._scroll_row
	var on_chip: Vector2 = strip.chips()[2].get_global_rect().get_center()
	await _hover(on_chip)
	_shot("chip-tooltip")
	strip_row.step(1)
	await _settle(REST_FRAMES)
	_shot("strip-scroll-closes-tooltip")
	await _hover(on_chip + Vector2(12.0, 0.0))
	_shot("moved-and-rested-shows-again")
	# What middle-click autoscroll does as it starts (a chip keeps its own
	# middle click: it shows the folder).
	TooltipCard.dismiss(get_viewport())
	await _settle(REST_FRAMES)
	_shot("autoscroll-start-closes-tooltip")
	await _hover(on_chip + Vector2(24.0, 0.0))
	_button(MOUSE_BUTTON_WHEEL_DOWN)
	await _settle(REST_FRAMES)
	_shot("wheel-closes-tooltip")
	strip_row.scroll_to(0, false)
	await _settle(10)

	# #27: the long texts autoscroll.
	var box: CommitBox = changes.commit_box()
	var body: TextEdit = box.find_child("Body", true, false) as TextEdit
	var output: TextEdit = box.find_child("Output", true, false) as TextEdit
	body.text = _lines("Description line", 60)
	output.text = _lines("hook: check", 60)
	output.show()
	await _settle(10)
	await _autoscroll_shot("commit-description-autoscroll", body, auto)
	await _autoscroll_shot("hook-output-autoscroll", output, auto)
	output.hide()
	body.text = ""

	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	var commits: CommitList = history.commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 150):
		return
	commits.select_only(4)
	if not await _wait(func() -> bool: return history.details().summary_text() == "Migrate the order tables"):
		return
	await _settle(20)
	var message: RichTextLabel = history.details().header().find_child("Body", true, false) as RichTextLabel
	await _autoscroll_shot("commit-message-autoscroll", message, auto)

	page.show_view(WorktreeView.View.CHANGES)
	var readme: int = -1
	for row: int in list.row_count():
		if list.path_at(row) == "README.md":
			readme = row
	list.select_only(readme)
	var panel: DiffPanel = changes.diff_panel()
	if not await _wait(func() -> bool: return panel.viewer() == "markdown"):
		return
	panel.choose_mode("preview")
	var preview: MarkdownDiffView = panel.markdown_view()
	if not await _wait(func() -> bool: return preview.block_count() > 0 and preview.built_count() == preview.block_count()):
		return
	await _settle(20)
	await _autoscroll_shot("markdown-preview-autoscroll", preview, auto)
	panel.choose_mode("unified")

	# #25: K scrolls the focused list back to its selected row.
	page.show_view(WorktreeView.View.HISTORY)
	commits.select_only(75)
	commits.set_scroll_offset(commits.max_scroll_offset())
	commits.grab_focus()
	await _settle(20)
	_shot("history-selection-out-of-view")
	_press("K")
	await _settle(10)
	_shot("history-k-reveals-selection")
	print("history: row 75 at %.0f of %.0f px" % [commits.row_top(75) - commits.scroll_offset(), commits.size.y])

	var search: LineEdit = history._search.text_box()
	commits.set_scroll_offset(0.0)
	search.grab_focus()
	await _settle(5)
	_type("k")
	await _settle(30)
	_shot("k-types-in-search")
	print("search: %s, list at %.0f" % [search.text, commits.scroll_offset()])
	history._search.set_text("")
	await _settle(10)

	page.show_view(WorktreeView.View.CHANGES)
	list.select_only(45)
	list.set_scroll_offset(0.0)
	list.grab_focus()
	await _settle(20)
	_shot("changes-selection-out-of-view")
	_press("K")
	await _settle(10)
	_shot("changes-k-reveals-selection")

	Actions.run_action(&"view.theme_light")
	await _settle(30)
	await _hover(on_chip)
	_shot("light-chip-tooltip")
	strip_row.step(1)
	await _settle(REST_FRAMES)
	_shot("light-strip-scroll-closes-tooltip")

	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


## Middle-clicks `target`'s upper part and shoots it a few frames into the
## autoscroll.
func _autoscroll_shot(file_name: String, target: Control, auto: AutoScroll) -> void:
	if target == null or not target.is_visible_in_tree():
		printerr("scrolling_screenshots: %s: nothing to scroll" % file_name)
		return
	var rect: Rect2 = target.get_global_rect()
	_move(rect.position + Vector2(rect.size.x / 2.0, minf(40.0, rect.size.y / 3.0)))
	await _settle(2)
	_middle_click()
	await _settle(6)
	print("%s: axes %s, autoscrolling %s: %s" % [file_name, AutoScroll.scroll_axes(target), auto.target() == target,
			auto.target()])
	_shot(file_name)
	auto.stop()
	await _settle(4)


func _lines(prefix: String, count: int) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for i: int in count:
		lines.append("%s %d" % [prefix, i + 1])
	return "\n".join(lines)


## Moves to `at` and waits there for a tooltip.
func _hover(at: Vector2) -> void:
	for i: int in 3:
		_move(at + Vector2(float(i), 0.0))
		await get_tree().process_frame
	var deadline: int = Time.get_ticks_msec() + 4000
	while _tooltip_popup() == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _settle(4)


func _shot(file_name: String) -> void:
	var image: Image = get_viewport().get_texture().get_image()
	var popup: PopupPanel = _tooltip_popup()
	var tip: String = "none"
	if popup != null:
		var card: Image = popup.get_texture().get_image()
		card.convert(image.get_format())
		var where: Vector2i = popup.position - get_window().position
		where.x = clampi(where.x, 0, maxi(0, image.get_width() - card.get_width()))
		where.y = clampi(where.y, 0, maxi(0, image.get_height() - card.get_height()))
		image.blit_rect(card, Rect2i(Vector2i.ZERO, card.get_size()), where)
		var tooltip_card: TooltipCard = popup.find_child("TooltipCard", true, false) as TooltipCard
		var label: Label = popup.find_child("*", true, false) as Label
		tip = str(tooltip_card.texts()) if tooltip_card != null else label.text if label != null else "?"
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT %s (tooltip: %s)" % [path, tip])


func _tooltip_popup() -> PopupPanel:
	for node: Node in get_tree().root.find_children("*", "PopupPanel", true, false):
		var popup: PopupPanel = node as PopupPanel
		if popup.visible and not popup.is_queued_for_deletion() and popup.theme_type_variation == &"TooltipPanel":
			return popup
	return null


func _move(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = at - _mouse
	_mouse = at
	get_viewport().push_input(motion, true)


func _button(index: MouseButton) -> void:
	for pressed: bool in [true, false]:
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = index
		click.pressed = pressed
		click.factor = 1.0
		click.position = _mouse
		click.global_position = _mouse
		get_viewport().push_input(click, true)


func _middle_click() -> void:
	for pressed: bool in [true, false]:
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_MIDDLE
		click.pressed = pressed
		click.button_mask = MOUSE_BUTTON_MASK_MIDDLE if pressed else 0
		click.position = _mouse
		click.global_position = _mouse
		get_viewport().push_input(click, true)


func _press(shortcut: String) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	event.physical_keycode = event.keycode
	get_viewport().push_input(event)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	get_viewport().push_input(release)


func _type(text: String) -> void:
	for ch: String in text:
		var event: InputEventKey = InputEventKey.new()
		event.pressed = true
		event.keycode = OS.find_keycode_from_string(ch.to_upper())
		event.physical_keycode = event.keycode
		event.unicode = ch.unicode_at(0)
		get_viewport().push_input(event)
		var release: InputEventKey = event.duplicate() as InputEventKey
		release.pressed = false
		get_viewport().push_input(release)


func _settle(frames: int) -> void:
	for i: int in frames:
		await get_tree().process_frame


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("scrolling_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true
