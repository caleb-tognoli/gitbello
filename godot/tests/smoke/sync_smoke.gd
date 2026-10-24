extends SmokeTest
## M5: fetch, pull and push from the keyboard. The fixture's remote has a
## commit `repo-8` has not fetched, so after a fetch `main` has diverged:
## a fast-forward pull fails with a toast that offers merge or rebase, the
## rebase fix pulls, and a push brings the branch level with the remote.
## Also: branches in the palette, and a missing editor reported as a toast.
## Uses fixture `repo-8`. Skipped without `--fixtures`.

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
	var buttons: Array[Button] = page.sync_buttons()
	expect_eq(buttons[2].text, "Push ↑1", "Push shows the commit to push")
	expect_eq(buttons[1].text, "Pull", "nothing to pull before fetching")

	# Ctrl+Shift+F fetches; the jobs bar shows it while it runs.
	var bar: JobsBar = main.jobs_bar()
	var seen_job: Array[bool] = [false]
	var watch: Callable = func(_job: int, label: String) -> void:
		seen_job[0] = seen_job[0] or label == "fetch"
	session.job_started.connect(watch)
	press("Ctrl+Shift+F")
	expect(await wait_until(func() -> bool: return _behind(session) == 1), "the fetch found one commit to pull")
	expect(seen_job[0], "the fetch ran as a job")
	expect(await wait_until(func() -> bool: return bar.job_count() == 0), "the jobs bar is empty again")
	expect(await wait_until(func() -> bool: return buttons[1].text == "Pull ↓1"), "Pull shows the commit to pull: %s" % buttons[1].text)
	session.job_started.disconnect(watch)

	# Ctrl+L pulls fast-forward only: refused, with fixes on the toast.
	var toasts: Toasts = main.toasts()
	press("Ctrl+L")
	expect(await wait_until(func() -> bool: return "Pull (rebase)" in toasts.fix_labels()),
			"a diverged pull offers merge or rebase: %s" % [toasts.fix_labels()])
	expect("Pull (merge)" in toasts.fix_labels(), "merge is offered too")
	expect(toasts.press_fix("Pull (rebase)"), "the rebase fix can be pressed")
	expect(await wait_until(func() -> bool: return _behind(session) == 0 and _ahead(session) == 1),
			"rebased onto the remote: ahead %d, behind %d" % [_ahead(session), _behind(session)])
	expect(FileAccess.file_exists(repo.path_join("remote.txt")), "the remote's file arrived")
	expect_eq(read_file(repo.path_join("app.txt")), "local edit\n", "local changes survived the pull")

	# Ctrl+P pushes.
	press("Ctrl+P")
	expect(await wait_until(func() -> bool: return _ahead(session) == 0), "Ctrl+P pushed the branch")
	expect(await wait_until(func() -> bool: return buttons[2].text == "Push"), "Push has nothing left: %s" % buttons[2].text)

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
