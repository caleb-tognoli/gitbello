extends SmokeTest
## M7.8 P2: image diffs show in the image viewer. A modified PNG offers the
## four image modes (the saved one, Ctrl+Shift+D cycles and saves them, Left/
## Right move the onion opacity and the divider), a small image fits by whole
## steps, the zoom bar, wheel, double-click and zoom shortcuts step through
## whole levels, the images stay in view however far they are dragged, the
## header shows the sizes, an SVG renders sharper than its size, added and
## deleted images show alone, a side past the limits says so (Load anyway
## past 20 MB), History shows a commit's image, and a binary image conflict
## previews ours and theirs. Uses the `images` fixtures (read-only here).
## Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("image_diff_smoke: no --fixtures, skipped")
		return
	var text_mode: String = Core.diff_mode("text")
	expect(Core.set_diff_mode("image", "split"), "the image mode saves")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("images"))
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	var images: ImageDiffView = panel.image_view()
	expect(await wait_until(func() -> bool: return session.change_count() == 6), "six changed images")

	# A modified PNG of another size.
	expect(await _select(changes, session, "logo.png"), "logo.png's diff loads")
	expect_eq(panel.viewer(), "image", "a PNG is drawn by the image viewer")
	expect_eq(panel.modes(), PackedStringArray(["split", "onion", "swipe", "difference"]), "the image modes")
	expect(panel.picker_visible() and panel.mode_button("onion") != null, "the picker shows the image modes")
	expect(images.is_visible_in_tree() and not panel.view().visible, "the image viewer replaces the lines")
	expect(await _loaded(images, true, true), "both sides decode")
	expect_eq(images.texture(ImageDiffView.OLD).get_size(), Vector2(64, 64), "the old side is 64×64")
	expect_eq(images.texture(ImageDiffView.NEW).get_size(), Vector2(80, 64), "the new side is 80×64")
	var stats: String = (panel.find_child("DiffStats", true, false) as Label).text
	expect(stats.contains("64×64 → 80×64"), "the header shows the dimensions: %s" % stats)
	expect(not panel.whole_file_button().visible, "no whole-file toggle for an image")
	_zooming(images)

	press("Ctrl+Shift+D")
	expect(panel.mode() == "onion" and images.mode == "onion", "Ctrl+Shift+D cycles to onion skin")
	expect_eq(Core.diff_mode("image"), "onion", "and saves it")
	expect_eq(Core.diff_mode("text"), text_mode, "the text mode is left alone")
	expect(images.onion_slider().visible, "onion skin shows its slider")
	images.grab_focus()
	press("Right")
	expect(is_equal_approx(images.onion_opacity(), 0.6), "Right raises the opacity by 10%")
	press("Shift+Left")
	expect(is_equal_approx(images.onion_opacity(), 0.59), "Shift+Left lowers it by 1%")
	press("Ctrl+Shift+D")
	expect_eq(images.mode, "swipe", "then swipe")
	expect(not images.onion_slider().visible, "swipe has no slider")
	images.grab_focus()
	press("Left")
	expect(is_equal_approx(images.swipe_position(), 0.4), "Left moves the divider")
	press("Ctrl+Shift+D")
	expect_eq(images.mode, "difference", "then difference")
	press("Ctrl+Shift+D")
	expect_eq(images.mode, "split", "and back to split")

	# An SVG: image modes only, rendered sharper than its 48×48.
	expect(await _select(changes, session, "icon.svg"), "icon.svg's diff loads")
	expect_eq(panel.viewer(), "image", "an SVG shows as an image")
	expect(await _loaded(images, true, true), "both SVG sides render")
	expect_eq(images.side_rect(ImageDiffView.NEW).size / images.scale_shown(), Vector2(48, 48), "it lays out at 48×48")
	expect(images.texture(ImageDiffView.NEW).get_width() > 48, "and renders sharper for zooming in")

	# A deleted and an added image show alone, without a picker.
	expect(await _select(changes, session, "old.png"), "old.png's diff loads")
	expect(panel.modes() == PackedStringArray(["single"]) and not panel.picker_visible(), "a deleted image shows alone")
	expect(await _loaded(images, true, false), "the old side decodes")
	expect_eq(Core.diff_mode("image"), "split", "showing it alone keeps the saved mode")
	expect(await _select(changes, session, "new.png"), "new.png's diff loads")
	expect(await _loaded(images, false, true), "the new side decodes")
	expect(panel.counts_text().is_empty(), "no line counts for an image")

	# Past the limits.
	expect(await _select(changes, session, "wide.png"), "wide.png's diff loads")
	expect_eq(images.message(ImageDiffView.NEW), "Too large to preview (17000×1)", "a 17000 px image is not decoded")
	expect(await _select(changes, session, "huge.png"), "huge.png's diff loads")
	expect(panel.message_text().contains("large") and not images.is_visible_in_tree(), "past 20 MB it asks first: %s" % panel.message_text())
	var load_anyway: Button = panel.find_child("LoadAnywayButton", true, false) as Button
	expect(load_anyway.visible, "with Load anyway")
	load_anyway.pressed.emit()
	expect(await wait_until(func() -> bool: return images.is_visible_in_tree() and images.texture(ImageDiffView.NEW) != null, 60_000),
			"Load anyway shows it")
	if images.texture(ImageDiffView.NEW) != null:
		expect_eq(images.side_rect(ImageDiffView.NEW).size / images.scale_shown(), Vector2(2400, 2400), "the whole image")
		expect_eq(images.texture(ImageDiffView.NEW).get_size(), Vector2(2048, 2048), "fitted, it shows a 2048 px preview")
		expect(images.fit_scale() < 1.0, "a large image shrinks to fit")
		images.zoom_out()
		expect(images.is_fit(), "it zooms out no further than the fit")
		images.zoom_bar_button(&"actual").pressed.emit()
		expect(await wait_until(func() -> bool: return images.texture(ImageDiffView.NEW).get_width() == 2400),
				"at 100% the full image replaces the preview")
		images.zoom_bar_button(&"fit").pressed.emit()
		expect(images.is_fit(), "Fit fits again")

	# A commit's image in History.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var history_panel: DiffPanel = details.diff_panel()
	var commits: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return commits.row_count() >= 2), "the commits load")
	commits.select_only(0)
	var history_images: ImageDiffView = history_panel.image_view()
	expect(await wait_until(func() -> bool: return history_panel.viewer() == "image"), "a commit's PNG shows as an image")
	expect(await _loaded(history_images, true, true), "both sides of the commit's PNG decode")

	# A binary image conflict previews both sides on its card.
	var conflict_page: RepoTab = main.open_repo(fixtures.path_join("images-conflict"))
	var conflict_session: RepoSession = conflict_page.session
	conflict_page.show_view(WorktreeView.View.CHANGES)
	var conflict_changes: ChangesView = conflict_page.changes()
	var conflict_panel: DiffPanel = conflict_changes.diff_panel()
	expect(await wait_until(func() -> bool: return conflict_session.change_count() >= 1), "the conflicted photo")
	conflict_changes.list().select_only(0)
	var preview: ImageDiffView = conflict_panel.image_preview()
	expect(await wait_until(func() -> bool: return conflict_panel.card_buttons().size() == 2), "the binary conflict's card")
	expect(await wait_until(func() -> bool: return preview.is_visible_in_tree()), "the card previews the sides")
	expect(await _loaded(preview, true, true), "ours and theirs decode")
	if preview.texture(ImageDiffView.NEW) != null:
		expect_eq(preview.texture(ImageDiffView.OLD).get_size(), Vector2(48, 32), "ours is 48×32")
		expect_eq(preview.texture(ImageDiffView.NEW).get_size(), Vector2(64, 40), "theirs is 64×40")
	expect(not preview.interactive, "the previews do not zoom")

	Core.set_diff_mode("image", "split")
	main.queue_free()
	await get_tree().process_frame


## The zoom of logo.png (64×64 → 80×64, much smaller than the view).
func _zooming(images: ImageDiffView) -> void:
	var fitted: float = images.scale_shown()
	expect(images.is_fit() and fitted >= 2.0 and is_equal_approx(fitted, roundf(fitted)),
			"a small image fits by whole steps: %s" % fitted)
	var bar: Control = images.zoom_bar()
	expect(bar.visible, "the zoom bar shows")
	expect_eq(images.zoom_bar_button(&"actual").text, "%d%%" % roundi(fitted * 100.0), "it shows the zoom")
	expect(images.zoom_bar_button(&"fit").disabled, "Fit is off while fitted")
	expect(Rect2(Vector2.ZERO, images.size).encloses(bar.get_rect()) and bar.position.x > images.size.x / 2.0
			and bar.position.y < images.size.y / 4.0, "the bar floats over the top-right corner: %s" % bar.get_rect())
	images.pan_by(Vector2(5000, 5000))
	expect_eq(images.pan(), Vector2.ZERO, "a fitted image does not move")
	expect(not images.can_pan(), "nor can it be dragged")

	Actions.run_action(&"image.zoom_actual")
	expect(not images.is_fit() and is_equal_approx(images.scale_shown(), 1.0), "Actual size shows 100%")
	expect_eq(images.zoom_bar_button(&"actual").text, "100%", "and the bar says so")
	images.zoom_out()
	expect(is_equal_approx(images.scale_shown(), 1.0), "a small image zooms out no further than 100%")
	expect(images.zoom_bar_button(&"zoom_out").disabled, "Zoom out is off there")
	Actions.run_action(&"image.zoom_in")
	expect(is_equal_approx(images.scale_shown(), 2.0), "Zoom in goes to the next whole level")
	press("Ctrl+Minus")
	expect(is_equal_approx(images.scale_shown(), 1.0), "Ctrl+- zooms out a level")
	expect_eq(Actions.shortcut_label(&"image.zoom_in"), "Ctrl+=", "zoom in shows as Ctrl+=")

	# The wheel zooms by whole levels at the cursor.
	var centre: Vector2 = images.side_rect(ImageDiffView.NEW).get_center()
	_wheel(images, MOUSE_BUTTON_WHEEL_UP, centre)
	expect(is_equal_approx(images.scale_shown(), 2.0), "a wheel notch zooms in a level: %s" % images.scale_shown())
	_wheel(images, MOUSE_BUTTON_WHEEL_UP, centre, 0.5)
	expect(is_equal_approx(images.scale_shown(), 2.0), "half a notch does not zoom yet")
	_wheel(images, MOUSE_BUTTON_WHEEL_UP, centre, 0.5)
	expect(is_equal_approx(images.scale_shown(), 3.0), "the other half does")

	# Zoomed past the view, it pans only as far as its edges.
	images.set_zoom(32.0, centre)
	expect(images.can_pan(), "zoomed in past the view, it can be dragged")
	# The new side is the larger: its edges stop at its half's.
	images.pan_by(Vector2(100000, 100000))
	var rect: Rect2 = images.side_rect(ImageDiffView.NEW)
	var margin: float = 12.0
	expect(rect.position.y <= margin + 0.5 and rect.position.x <= images.size.x / 2.0 + margin,
			"dragged far, its top-left edges stop at its half's: %s" % rect)
	images.pan_by(Vector2(-100000, -100000))
	rect = images.side_rect(ImageDiffView.NEW)
	expect(absf(rect.end.x - (images.size.x - margin)) <= 1.0 and rect.end.y >= images.size.y - margin - 40.0
			and rect.end.y <= images.size.y, "and the other way, at the view's: %s" % rect)

	# A double-click goes to 100% and back to fitted.
	images.fit()
	_double_click(images, centre)
	expect(is_equal_approx(images.scale_shown(), 1.0), "a double-click shows 100%")
	_double_click(images, centre)
	expect(images.is_fit(), "another fits again")


func _wheel(images: ImageDiffView, index: MouseButton, at: Vector2, factor: float = 1.0) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = index
	event.pressed = true
	event.position = at
	event.factor = factor
	images._gui_input(event)


func _double_click(images: ImageDiffView, at: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.double_click = true
	event.position = at
	images._gui_input(event)
	var release: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	release.pressed = false
	release.double_click = false
	images._gui_input(release)


## Waits for the images `view` should show: `old` and `new` decoded (or none).
func _loaded(view: ImageDiffView, old: bool, new: bool) -> bool:
	return await wait_until(func() -> bool:
		return (view.texture(ImageDiffView.OLD) != null) == old and (view.texture(ImageDiffView.NEW) != null) == new)


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		return false
	changes.list().select_only(index)
	return await wait_until(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready" \
				and changes.diff_panel().modes() == PackedStringArray(info.get("modes", PackedStringArray())))
