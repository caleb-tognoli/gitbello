extends SmokeTest
## The delete dialogs' item rows and the worktree delete's checks. A click
## right on a row's check box toggles it once (the row and the box used to
## toggle it twice), as does a click on its name, and Space. With
## `--fixtures`, on a repository built for it: a squash-merged branch's row
## fills in as "squash-merged" and ticks itself; a detached worktree offers
## to keep its commits on no branch as a branch (renamed here) and keeps
## them; a rebasing worktree offers its branch, unticked, and says the
## rebase goes.

const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
const MAIN: PackedScene = preload("res://app/main/main.tscn")
const AUTHOR: PackedStringArray = ["-c", "user.name=Smoke", "-c", "user.email=smoke@example.com"]


func run() -> void:
	await _test_item_clicks()
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("delete_worktree_smoke: no --fixtures, skipped the worktree checks")
		return
	var repo: String = fixtures.path_join("delete-dialog")
	_build_repo(repo)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 4 and session.is_ready()),
			"the three linked worktrees are listed")
	var form: FormDialog = page.ops().form()
	await _squashed(page, session, form)
	await _detached(page, session, form, repo)
	await _rebasing(page, session, form)
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _test_item_clicks() -> void:
	var form: FormDialog = FORM.instantiate() as FormDialog
	add_child(form)
	form.begin("Delete worktree", "Delete", func(_values: Dictionary) -> void: pass)
	var check: CheckBox = form.add_item("item", &"GitBranch", "topic", false, false, [{"text": "merged", "tone": &"success"}])
	form.open()
	await get_tree().process_frame
	await get_tree().process_frame
	_click(form, check.get_global_rect().get_center())
	expect(check.button_pressed, "a click on the box ticks it once")
	_click(form, check.get_global_rect().get_center())
	expect(not check.button_pressed, "another click unticks it")
	var chip: Control = check.get_parent().get_child(check.get_index() + 2) as Control
	_click(form, chip.get_global_rect().get_center())
	expect(check.button_pressed, "a click on the name ticks it")
	check.grab_focus()
	press("Space", form)
	await get_tree().process_frame
	expect(not check.button_pressed, "Space unticks it")
	form.set_item_facts("item", [{"text": "Checking…", "busy": true}])
	await get_tree().process_frame
	expect_eq(form.item_facts("item"), PackedStringArray(["Checking…"]), "facts can change while open")
	form.suggest_item("item", true)
	expect(not check.button_pressed, "a suggestion leaves a box the user changed")
	form.hide()
	form.queue_free()


## A left click (press and release) at `at` in `window`.
func _click(window: Window, at: Vector2) -> void:
	for pressed: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		window.push_input(event)


func _squashed(page: RepoTab, session: RepoSession, form: FormDialog) -> void:
	expect(await _menu_for(page, session, "wt-squashed", "Delete…"), "the menu offers delete")
	expect(await wait_until(func() -> bool: return form.visible and form.field("delete_branch") != null),
			"the dialog opens with the branch")
	var branch: CheckBox = form.field("delete_branch") as CheckBox
	expect(await wait_until(func() -> bool: return branch.button_pressed), "a squash-merged branch ticks itself")
	expect_eq(form.item_facts("delete_branch"), PackedStringArray(["squash-merged"]),
			"its row says it is squash-merged")
	form.hide()


func _detached(page: RepoTab, session: RepoSession, form: FormDialog, repo: String) -> void:
	expect(await _menu_for(page, session, "wt-detached", "Delete…"), "a detached worktree can be deleted")
	expect(await wait_until(func() -> bool: return form.visible and form.field("keep") != null),
			"keeping its commits is offered")
	var keep: CheckBox = form.field("keep") as CheckBox
	expect(keep.button_pressed, "and ticked")
	expect(form.field("delete_branch") == null, "no branch is offered")
	await get_tree().process_frame
	_click(form, keep.get_global_rect().get_center())
	expect(not keep.button_pressed, "a click unticks keeping")
	expect("1 commit on no branch" in form.item_facts("folder"), "unticked, the folder says what goes")
	await get_tree().process_frame
	await get_tree().process_frame
	_click(form, keep.get_global_rect().get_center())
	expect(keep.button_pressed, "another click ticks it again")
	expect(not "1 commit on no branch" in form.item_facts("folder"), "ticked, nothing is lost")
	var rename: LineEdit = form.field("keep_name") as LineEdit
	await get_tree().process_frame
	var chip: Control = rename.get_parent().get_child(rename.get_index() - 1) as Control
	_click(form, chip.get_global_rect().get_center())
	expect(rename.visible and not chip.visible, "a click on the name edits it")
	expect_eq(rename.text, "wt-detached", "the new branch is named after the folder")
	rename.text = "main"
	rename.text_changed.emit(rename.text)
	expect(form.get_ok_button().disabled, "a name in use is refused")
	rename.text = "kept"
	rename.text_changed.emit(rename.text)
	expect(not form.get_ok_button().disabled, "a free name is fine")
	var head: String = _git(repo.path_join("../wt-detached").simplify_path(), ["rev-parse", "HEAD"])
	expect(form.submit(), "delete submitted")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "the worktree was deleted")
	expect_eq(_git(repo, ["rev-parse", "refs/heads/kept"]), head, "its commit is on the new branch")


func _rebasing(page: RepoTab, session: RepoSession, form: FormDialog) -> void:
	expect(await _menu_for(page, session, "wt-rebasing", "Delete…"), "a rebasing worktree can be deleted")
	expect(await wait_until(func() -> bool: return form.visible and form.field("delete_branch") != null),
			"its branch is offered")
	var branch: CheckBox = form.field("delete_branch") as CheckBox
	var checked: Callable = func() -> bool:
		var facts: PackedStringArray = form.item_facts("delete_branch")
		return not facts.is_empty() and not "Checking…" in facts
	expect(await wait_until(checked), "the branch's check arrives")
	expect(not branch.button_pressed, "a rebasing branch is not ticked")
	expect_eq(form.item_facts("delete_branch"), PackedStringArray(["1 not in main"]), "and says what is not in main")
	expect("rebasing" in form.item_facts("folder"), "the folder says the rebase goes")
	expect(form.submit(), "delete submitted")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 2), "the worktree was deleted")
	expect(_has_branch(session, "rebasing"), "its branch stays")


## `repo`: `main`; `squashed`, squash-merged into main, in worktree
## `wt-squashed`; `wt-detached` with a commit on no branch; `wt-rebasing` on
## `rebasing`, stopped in a rebase onto main.
func _build_repo(repo: String) -> void:
	DirAccess.make_dir_recursive_absolute(repo)
	_git(repo, ["init", "-q", "-b", "main"])
	write_file(repo.path_join("a.txt"), "a\n")
	_commit(repo, "first")
	_git(repo, ["switch", "-q", "-c", "squashed"])
	write_file(repo.path_join("s.txt"), "1\n")
	_commit(repo, "squashed 1")
	write_file(repo.path_join("t.txt"), "2\n")
	_commit(repo, "squashed 2")
	_git(repo, ["switch", "-q", "-c", "rebasing", "main"])
	write_file(repo.path_join("a.txt"), "rebasing\n")
	_commit(repo, "rebasing a")
	_git(repo, ["switch", "-q", "main"])
	_git(repo, ["merge", "--squash", "-q", "squashed"])
	_commit(repo, "Squashed (#1)")
	write_file(repo.path_join("a.txt"), "main\n")
	_commit(repo, "main a")
	_git(repo, ["worktree", "add", "-q", "../wt-squashed", "squashed"])
	_git(repo, ["worktree", "add", "-q", "--detach", "../wt-detached", "main"])
	_commit(repo.path_join("../wt-detached").simplify_path(), "on no branch", true)
	var rebasing: String = repo.path_join("../wt-rebasing").simplify_path()
	_git(repo, ["worktree", "add", "-q", "../wt-rebasing", "rebasing"])
	_git(rebasing, AUTHOR + PackedStringArray(["rebase", "main"]))


func _commit(dir: String, message: String, empty: bool = false) -> void:
	_git(dir, ["add", "-A"])
	var args: PackedStringArray = AUTHOR + PackedStringArray(["commit", "-q", "-m", message])
	if empty:
		args.append("--allow-empty")
	_git(dir, args)


func _menu_for(page: RepoTab, session: RepoSession, folder: String, label: String) -> bool:
	if not await wait_until(func() -> bool: return not _worktree(session, folder).is_empty()):
		return false
	page.strip().worktree_menu_requested.emit(_worktree(session, folder), Vector2.ZERO)
	return page.press_menu(label)


static func _worktree(session: RepoSession, folder: String) -> Dictionary:
	for wt: Dictionary in session.worktrees():
		if String(wt["path"]).ends_with(folder):
			return wt
	return {}


static func _has_branch(session: RepoSession, branch: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == branch:
			return true
	return false


## Runs git in `dir` and returns its output, trimmed.
static func _git(dir: String, args: PackedStringArray) -> String:
	var output: Array = []
	OS.execute("git", PackedStringArray(["-C", dir]) + args, output, true)
	return String(output[0]).strip_edges() if not output.is_empty() else ""
