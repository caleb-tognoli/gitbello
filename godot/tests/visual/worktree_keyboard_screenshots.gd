extends Node

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repo.is_empty() or out.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var deadline: int = Time.get_ticks_msec() + 30_000
	while Time.get_ticks_msec() < deadline:
		if page.strip().chips().size() > 1 and page.history().commit_list().row_count() > 0:
			break
		await get_tree().process_frame
	if page.strip().chips().size() < 2:
		get_tree().quit(1)
		return
	page.history().commit_list().select_only(0)
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		page.focus_view()
		await _shot(out, mode + "_unfocused")
		_focus(page.strip().chips()[0])
		await _shot(out, mode + "_selected_chip_focus")
		_focus(page.strip().chips()[1])
		await _shot(out, mode + "_other_chip_focus")
		_focus(page.strip().new_task_button())
		await _shot(out, mode + "_new_button_focus")
		var more: Button = page.strip().new_task_button().get_parent().get_child(1) as Button
		_focus(more)
		await _shot(out, mode + "_more_button_focus")
	var worktrees: Array[Dictionary] = []
	var template: Dictionary = page.strip().chips()[0].worktree.duplicate()
	for i: int in 14:
		var wt: Dictionary = template.duplicate()
		wt["path"] = "/preview/worktree-%02d" % i
		wt["name"] = "worktree-%02d-long-name" % i
		wt["is_main"] = i == 0
		worktrees.append(wt)
	page.strip().show_worktrees(worktrees, String(worktrees[0]["path"]))
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		page.focus_view()
		await _shot(out, mode + "_overflow_unfocused")
		_focus(page.strip().chips()[13])
		await _shot(out, mode + "_overflow_last_chip_focus")
		var all: Button = page.strip().get_child(0).get_child(1) as Button
		_focus(all)
		await _shot(out, mode + "_overflow_button_focus")
	main.close_tab(0)
	get_tree().quit()


func _focus(control: Control) -> void:
	if control.focus_mode != Control.FOCUS_NONE:
		control.grab_focus()


func _shot(out: String, label: String) -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	RenderingServer.force_draw()
	var error: Error = get_viewport().get_texture().get_image().save_png(out.path_join(label + ".png"))
	if error != OK:
		push_error("Screenshot failed: %s" % label)
	else:
		print("CAPTURE ", out.path_join(label + ".png"))
