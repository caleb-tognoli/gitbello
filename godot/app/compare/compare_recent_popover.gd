class_name CompareRecentPopover
extends PopupPanel
## The repository's recent comparisons (PLAN M7.12c), opened from the
## Recent button at the right of Compare's bar: a row each, "left ⇄ right",
## newest first. A click or Enter reopens one.

## A recent comparison was chosen: `{left, right, working, mode}`.
signal chosen(recent: Dictionary)

var _rows: VBoxContainer = VBoxContainer.new()
var _empty: Label = Label.new()


func _ready() -> void:
	theme_type_variation = &"WorktreeListPanel"
	_rows.theme_type_variation = &"WorktreeListRows"
	add_child(_rows)
	_empty.theme_type_variation = &"DimLabel"


## Opens under `anchor`, from its left edge, with a row per
## entry of `recent` (`Core.compare_recent`).
func open_below(anchor: Control, recent: Array[Dictionary]) -> void:
	fill(recent)
	var scale: float = anchor.get_window().content_scale_factor
	popup(Rect2i(Vector2i(anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)), Vector2i.ZERO))
	reset_size()
	size = Vector2i(Vector2(size) * scale)
	var corner: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	position = Vector2i(corner)
	if _rows.get_child_count() > 0 and _rows.get_child(0) is Button:
		(_rows.get_child(0) as Control).grab_focus.call_deferred()


## Builds a row per entry of `recent`.
func fill(recent: Array[Dictionary]) -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		if child != _empty:
			child.queue_free()
	if recent.is_empty():
		_empty.text = tr("No other recent comparisons")
		_rows.add_child(_empty)
		return
	for entry: Dictionary in recent:
		var row: Button = Button.new()
		row.theme_type_variation = &"WorktreeListRow"
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_ALL
		row.icon = AppTheme.icon(&"GitCompare")
		row.text = CompareRecentPopover.label(entry)
		row.tooltip_text = tr("Open this comparison again")
		row.set_meta(&"recent", entry)
		row.pressed.connect(func() -> void:
			hide()
			chosen.emit(entry))
		_rows.add_child(row)


## "left ⇄ right": a commit side by its subject, the working copy by name.
static func label(entry: Dictionary) -> String:
	var left: String = String(entry.get("left_name", ""))
	var right: String = String(entry.get("right_name", ""))
	if left.is_empty():
		left = String(entry["left"])
	if bool(entry["working"]):
		right = String(TranslationServer.translate("Working copy"))
	elif right.is_empty():
		right = String(entry["right"])
	return "%s ⇄ %s" % [left, right]


## The rows' labels, for tests.
func labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for row: Node in _rows.get_children():
		if row is Button:
			out.append((row as Button).text)
	return out


## Chooses the row labelled `text` as a click would (for tests).
func choose(text: String) -> bool:
	for row: Node in _rows.get_children():
		if row is Button and (row as Button).text == text:
			(row as Button).pressed.emit()
			return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _empty.get_parent() == null:
		_empty.free()
