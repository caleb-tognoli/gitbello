extends Node
## Tooltip cards, in numbered shots with the tooltip drawn in: real
## hovers (pushed mouse moves) over the view switch, the branch and Sync
## buttons, the commit button (greyed, with why), a diff's mode and whole-file
## buttons, History's next-match button and a worktree chip; the palette's
## disabled reasons; then the light theme. Each shot prints the card's lines. Pass --repo=<CLI fixture repo-1>
## --out=<directory>, with GITBELLO_CONFIG set to a scratch config, windowed
## (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 1
var _main: Main = null


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("tooltip_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var view: WorktreeView = page.active_view()
	var changes: ChangesView = page.changes()
	changes.list().select_only(0)
	await _settle(30)
	get_viewport().notify_mouse_entered()

	var switch_button: Button = null
	for button: Button in view._switch_actions:
		if view._switch_actions[button] == &"view.history":
			switch_button = button
	await _hover_shot("view-switch-history", switch_button)
	await _hover_shot("branch-button", view._branch_button)
	await _hover_shot("sync-button", view._sync_button)
	await _hover_shot("commit-button-disabled", changes.commit_box()._commit_button)
	var panel: DiffPanel = changes.diff_panel()
	if await _wait(func() -> bool: return panel._switch.get_child_count() > 0):
		await _hover_shot("diff-mode-unified", panel._switch.get_child(0) as Control)
	if panel._whole_button.visible:
		await _hover_shot("diff-whole-file", panel._whole_button)
	var chips: Array[WorktreeChip] = page.strip().chips()
	if not chips.is_empty():
		await _hover_shot("worktree-chip", chips[0])

	page.show_view(WorktreeView.View.HISTORY)
	await _settle(30)
	var history: HistoryView = page.history()
	if not history._match_buttons.is_empty():
		history._match_buttons[1].visible = true
		await _settle(5)
		await _hover_shot("history-next-match", history._match_buttons[1])

	# Disabled reasons as the palette lists them.
	page.show_view(WorktreeView.View.CHANGES)
	await _settle(20)
	for query: String in ["undo", "conflict", "compare", "shelf"]:
		_main.palette().open()
		_main.palette().set_query(query)
		await _settle(10)
		_shot("palette-" + query)
		_main.palette().close()
		await _settle(5)

	Actions.run_action(&"view.theme_light")
	await _settle(30)
	await _hover_shot("branch-button-light", view._branch_button)
	await _hover_shot("commit-button-light", changes.commit_box()._commit_button)

	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


## Moves the mouse over `control`, waits for its tooltip and shoots it.
func _hover_shot(file_name: String, control: Control) -> void:
	if control == null or not control.is_visible_in_tree():
		print("tooltip_screenshots: %s: nothing to hover" % file_name)
		return
	# Away first, so the tooltip of the last control closes.
	_move(Vector2(get_viewport().get_visible_rect().size.x - 4, get_viewport().get_visible_rect().size.y - 4))
	await _settle(10)
	var at: Vector2 = control.get_global_rect().get_center()
	for i: int in 3:
		_move(at)
		await get_tree().process_frame
	var popup: PopupPanel = null
	var deadline: int = Time.get_ticks_msec() + 4000
	while popup == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		popup = _tooltip_popup()
	await _settle(4)
	var image: Image = get_viewport().get_texture().get_image()
	if popup == null:
		printerr("tooltip_screenshots: %s: no tooltip (text %s)" % [file_name, control.tooltip_text.c_escape()])
	else:
		var tip: Image = popup.get_texture().get_image()
		tip.convert(image.get_format())
		var where: Vector2i = popup.position - get_window().position
		where.x = clampi(where.x, 0, maxi(0, image.get_width() - tip.get_width()))
		where.y = clampi(where.y, 0, maxi(0, image.get_height() - tip.get_height()))
		image.blit_rect(tip, Rect2i(Vector2i.ZERO, tip.get_size()), where)
		var card: TooltipCard = popup.find_child("TooltipCard", true, false) as TooltipCard
		var lines: String = str(card.texts()) if card != null else control.tooltip_text.c_escape()
		print("%s %s" % [file_name, lines])
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)


func _shot(file_name: String) -> void:
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _tooltip_popup() -> PopupPanel:
	for child: Node in get_viewport().get_children(true):
		var popup: PopupPanel = child as PopupPanel
		if popup != null and popup.visible and popup.theme_type_variation == &"TooltipPanel":
			return popup
	for node: Node in get_tree().root.find_children("*", "PopupPanel", true, false):
		var popup: PopupPanel = node as PopupPanel
		if popup.visible and popup.get_child_count(true) > 0:
			for child: Node in popup.get_children(true):
				if child is Label and (child as Label).theme_type_variation == &"TooltipLabel":
					return popup
				if child.get_class() == "VBoxContainer" and child.has_method(&"get_theme_type_variation") \
						and String((child as Control).theme_type_variation).begins_with("WorktreeTooltip"):
					return popup
	return null


func _move(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion, true)


func _settle(frames: int) -> void:
	for i: int in frames:
		await get_tree().process_frame


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("tooltip_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true
