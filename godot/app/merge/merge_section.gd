class_name MergeSection
extends VBoxContainer
## A folding list of the merge dialog ("Conflicts · 2", "Commits · 3"): a
## header with a chevron and the count, then its rows in a frame that is as
## tall as they are up to `max_height`, then scrolls.

## The header was clicked.
signal folded_changed()

## The most the rows take before they scroll, and one row's height.
var max_height: float = 144.0:
	set(value):
		max_height = value
		_fit()
var row_height: float = 24.0
## The user folded or unfolded it (code doesn't override that choice).
var touched: bool = false

var _header: Button = Button.new()
var _scroll: ScrollContainer = ScrollContainer.new()
var _rows: VBoxContainer = VBoxContainer.new()
var _keys: PackedStringArray = PackedStringArray()
var _folded: bool = false


func _init() -> void:
	add_theme_constant_override(&"separation", 4)
	_header.theme_type_variation = &"DisclosureButton"
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.focus_mode = Control.FOCUS_NONE
	_header.pressed.connect(func() -> void:
		touched = true
		set_folded(not _folded)
		folded_changed.emit())
	add_child(_header)
	_scroll.theme_type_variation = &"FormList"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override(&"separation", 0)
	_rows.minimum_size_changed.connect(_fit)
	_scroll.add_child(_rows)
	add_child(_scroll)
	_set_arrow()


## "Conflicts · 2".
func set_title(title: String, count: int) -> void:
	_header.text = "%s · %d" % [title, count]


func header_text() -> String:
	return _header.text


func is_folded() -> bool:
	return _folded


func set_folded(folded: bool) -> void:
	_folded = folded
	_scroll.visible = not folded
	_set_arrow()


func header() -> Button:
	return _header


func clear_rows() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_keys.clear()


## Adds `row`, at least a row tall; `key` names it for tests ("" for none).
func add_row(row: Control, key: String) -> void:
	row.custom_minimum_size.y = maxf(row.custom_minimum_size.y, row_height)
	_rows.add_child(row)
	if not key.is_empty():
		_keys.append(key)


func row_keys() -> PackedStringArray:
	return _keys.duplicate()


## The scrolling frame (for tests: whether it is capped).
func scroll() -> ScrollContainer:
	return _scroll


func _fit() -> void:
	var frame: float = _scroll.get_theme_stylebox(&"panel").get_minimum_size().y
	_scroll.custom_minimum_size.y = minf(_rows.get_combined_minimum_size().y, max_height) + frame


func _set_arrow() -> void:
	_header.icon = AppTheme.icon(&"GuiTreeArrowRight" if _folded else &"GuiTreeArrowDown")
