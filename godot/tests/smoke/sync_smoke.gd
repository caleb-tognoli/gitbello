extends SmokeTest
## M5, reworked in M6.5 P2: the Sync button. The fixture's remote has a
## commit `repo-8` has not fetched, so after a fetch `main` has diverged:
## Sync (with the default ff-only pulls) offers merge or rebase on a toast,
## the rebase choice pulls then pushes, showing its progress on the button,
## and ends with a success toast. Also: a fetch from the keyboard shows a
## progress toast, branches in the palette, and a missing editor reported as
## a toast. Uses fixture `repo-8`. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("sync_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-8")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.can_push() and session.can_fetch()),
			"the repository is ready to sync")
	var button: BigButton = page.active_view().sync_button()
	expect(await wait_until(func() -> bool: return button.text == "Push ↑1"), "Sync shows the commit to push: %s" % button.text)

	# Ctrl+Shift+F fetches; with no button behind it, a progress toast shows it.
	var toasts: Toasts = main.toasts()
	press("Ctrl+Shift+F")
	expect(await wait_until(func() -> bool: return toasts.toast_texts().has("Fetching repo-8…")),
			"a progress toast shows the fetch: %s" % [toasts.toast_texts()])
	expect(await wait_until(func() -> bool: return _behind(session) == 1), "the fetch found one commit to pull")
	expect(await wait_until(func() -> bool: return not toasts.toast_texts().has("Fetching repo-8…")),
			"the progress toast goes when the fetch ends")
	expect(await wait_until(func() -> bool: return button.text == "Sync ↓1 ↑1"),
			"Sync shows both directions: %s" % button.text)

	# Sync on diverged branches with ff-only pulls: merge or rebase, then push.
	expect(Actions.run_action(&"sync.sync", button), "Sync runs")
	expect(await wait_until(func() -> bool: return "Pull (rebase)" in toasts.fix_labels()),
			"a diverged sync offers merge or rebase: %s" % [toasts.fix_labels()])
	expect("Pull (merge)" in toasts.fix_labels(), "merge is offered too")
	var busy_seen: Array[bool] = [false]
	var watch: Callable = func(_job: int, _label: String) -> void:
		busy_seen[0] = busy_seen[0] or button.is_busy()
	session.job_started.connect(watch)
	expect(toasts.press_fix("Pull (rebase)"), "the rebase choice can be pressed")
	expect(button.is_busy(), "the button shows the job it started")
	expect(await wait_until(func() -> bool: return _behind(session) == 0 and _ahead(session) == 0),
			"rebased and pushed: ahead %d, behind %d" % [_ahead(session), _behind(session)])
	session.job_started.disconnect(watch)
	expect(FileAccess.file_exists(repo.path_join("remote.txt")), "the remote's file arrived")
	expect_eq(read_file(repo.path_join("app.txt")), "local edit\n", "local changes survived the pull")
	expect(await wait_until(func() -> bool: return toasts.toast_texts().has("Synced main with origin")),
			"a success toast says so: %s" % [toasts.toast_texts()])
	expect(await wait_until(func() -> bool: return not button.is_busy() and button.text == "Fetch"),
			"Sync has nothing left but fetching: %s" % button.text)

	# The palette lists branches to check out.
	press("Ctrl+K")
	var palette: CommandPalette = main.palette()
	expect(await wait_until(func() -> bool: return palette.visible), "Ctrl+K opens the palette")
	expect("Check out: feature/login" in palette.visible_labels(), "branches are in the palette: %s" % [palette.visible_labels()])
	expect(not ("Check out: main" in palette.visible_labels()), "the checked-out branch is not")
	palette.close()

	# The smoke config's editor does not exist: a toast says so.
	var before: int = toasts.toast_count()
	press("Ctrl+Shift+E")
	expect(await wait_until(func() -> bool: return toasts.toast_count() > before), "a missing editor is reported")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


static func _ahead(session: RepoSession) -> int:
	return int(session.badge().get("ahead", -1))


static func _behind(session: RepoSession) -> int:
	return int(session.badge().get("behind", -1))
