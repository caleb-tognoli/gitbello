extends Node
## Capture of the Sync button and the commits to push and pull: Push with
## one outgoing commit, the ▾ menu, the busy state at two progress steps,
## Sync after a fetch finds an incoming commit, the branch list, the worktree
## chip's tooltip, the list of every worktree, the "No local changes"
## suggestion and Home. Pass
## --fixtures=<CLI fixture dir> --out=<directory>, with GITBELLO_CONFIG at a
## scratch config inside it, and launch windowed. It fetches `repo-8` from its
## local remote, and expects `repo-1` without changes (stash them first):
## throwaway CLI fixtures only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var fixtures: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			fixtures = arg.trim_prefix("--fixtures=").replace("\\", "/")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var config: String = OS.get_environment("GITBELLO_CONFIG").replace("\\", "/")
	if fixtures.is_empty() or out.is_empty() or config.get_base_dir() != fixtures \
			or not FileAccess.file_exists(fixtures.path_join("global.gitconfig")):
		printerr("sync_button_screenshots: use CLI fixtures and a scratch config inside them")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = main.open_repo(fixtures.path_join("repo-8"))
	var session: RepoSession = page.session
	var view: WorktreeView = page.active_view()
	var button: BigButton = view.sync_button()
	if not await _wait(func() -> bool: return session.is_ready() and button.text == "Push"):
		return
	await _shot(out, "01-push")
	button.menu_requested.emit()
	await _shot(out, "02-menu")
	_close_menus(view)
	# What a push looks like on the button: the caption stays, git's progress
	# goes to the tooltip.
	var doing: String = tr("Pushing %s") % session.current_branch() + "…"
	button.set_busy(true, tr("Pushing") + "…", -1, doing)
	await _shot(out, "03-busy-start")
	button.set_busy(true, tr("Pushing") + "…", 45, doing + "\nWriting objects:  45% (3/7)")
	await _shot(out, "04-busy-writing")
	button.menu_requested.emit()
	await _shot(out, "05-busy-menu")
	_close_menus(view)
	button.set_busy(false, "", -1, "")
	session.fetch()
	if not await _wait(func() -> bool: return button.text == "Sync" and button.counts().behind == 1):
		return
	await get_tree().create_timer(1.0).timeout
	await _shot(out, "06-sync")
	view.open_branches()
	await _shot(out, "07-branches")
	view.branch_popover().hide()
	var chip: WorktreeChip = page.strip().chips()[0]
	var tooltip: Control = chip._make_custom_tooltip(chip.tooltip_text)
	var holder: PanelContainer = PanelContainer.new()
	holder.theme_type_variation = &"TooltipPanel"
	holder.position = chip.global_position + Vector2(0.0, chip.size.y + 6.0)
	holder.add_child(tooltip)
	add_child(holder)
	holder.reset_size()
	await _shot(out, "08-chip-tooltip")
	holder.queue_free()
	page.strip().list_button().pressed.emit()
	await _shot(out, "09-worktree-list")
	page.strip().all_list().hide()
	Actions.run_action(&"view.theme_light")
	await _shot(out, "10-sync-light")
	Actions.run_action(&"view.theme_dark")
	var clean: RepoTab = main.open_repo(fixtures.path_join("repo-1"))
	var clean_sync: BigButton = clean.active_view().sync_button()
	if not await _wait(func() -> bool: return clean.session.is_ready() and clean.session.change_count() == 0 \
			and clean_sync.text == "Push"):
		return
	clean.show_view(WorktreeView.View.CHANGES)
	await _shot(out, "11-no-changes")
	Actions.run_action(&"home.open")
	await _shot(out, "12-home")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _close_menus(view: WorktreeView) -> void:
	for child: Node in view.get_children():
		if child is PopupMenu:
			(child as PopupMenu).hide()


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("sync_button_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(out: String, file_name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = out.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
