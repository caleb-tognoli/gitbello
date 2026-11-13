extends SmokeTest
## M5, reworked in M6.5 P2: the Sync button. The fixture's remote has a
## commit `repo-8` has not fetched, so after a fetch `main` has diverged:
## Sync (with the default ff-only pulls) offers merge or rebase on a toast,
## the rebase choice pulls then pushes, showing its progress on the button,
## and ends without a success toast (the button shows the result). Also: a
## fetch from the keyboard shows a progress toast, branches in the palette,
## and a missing terminal reported as a toast. Uses fixture `repo-8`. Skipped
## without `--fixtures`.

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
	expect(await wait_until(func() -> bool: return button.text == "Push" and button.counts().ahead == 1),
			"Sync shows the commit to push: %s" % button.text)

	# Ctrl+Shift+F fetches; with no button behind it, a progress toast shows it.
	var toasts: Toasts = main.toasts()
	press("Ctrl+Shift+F")
	expect(await wait_until(func() -> bool: return toasts.toast_texts().has("Fetching repo-8…")),
			"a progress toast shows the fetch: %s" % [toasts.toast_texts()])
	expect(await wait_until(func() -> bool: return _behind(session) == 1), "the fetch found one commit to pull")
	expect(await wait_until(func() -> bool: return not toasts.toast_texts().has("Fetching repo-8…")),
			"the progress toast goes when the fetch ends")
	expect(await wait_until(func() -> bool: return button.text == "Sync" and button.counts().ahead == 1 \
			and button.counts().behind == 1),
			"Sync shows both directions: %s" % button.text)

	# Sync on diverged branches with ff-only pulls: merge or rebase, then push.
	expect(Actions.run_action(&"sync.sync", button), "Sync runs")
	expect(await wait_until(func() -> bool: return "Pull and rebase" in toasts.fix_labels()),
			"a diverged sync offers merge or rebase: %s" % [toasts.fix_labels()])
	expect("Pull and merge" in toasts.fix_labels(), "merge is offered too")
	var busy_seen: Array[bool] = [false]
	var watch: Callable = func(_job: int, _label: String) -> void:
		busy_seen[0] = busy_seen[0] or button.is_busy()
	session.job_started.connect(watch)
	expect(toasts.press_fix("Pull and rebase"), "the rebase choice can be pressed")
	expect(button.is_busy(), "the button shows the job it started")
	expect(await wait_until(func() -> bool: return _behind(session) == 0 and _ahead(session) == 0),
			"rebased and pushed: ahead %d, behind %d" % [_ahead(session), _behind(session)])
	session.job_started.disconnect(watch)
	expect(FileAccess.file_exists(repo.path_join("remote.txt")), "the remote's file arrived")
	expect_eq(read_file(repo.path_join("app.txt")), "local edit\n", "local changes survived the pull")
	expect(await wait_until(func() -> bool: return not button.is_busy() and button.text == "Fetch"),
			"Sync has nothing left but fetching: %s" % button.text)
	expect_eq(toasts.toast_count(), 0, "the button shows the result, so no success toast repeats it")

	# Amending a pushed commit on main (a shared branch): Sync asks, with
	# Force push as a third choice, and the confirmation names the rewrite.
	var ops: RepoOps = page.active_view().ops()
	await _commit_and_push(repo, session, button, "main.txt")
	expect(await wait_until(func() -> bool: return _ahead(session) == 0 and not button.is_busy()), "main is pushed")
	_git(repo, ["commit", "--amend", "--quiet", "-m", "main work, amended"])
	session.refresh()
	expect(await wait_until(func() -> bool: return session.upstream_rewrite().get("shared", false) == true),
			"the amend is a rewrite of a shared branch: %s" % [session.upstream_rewrite()])
	expect_eq(button.text, "Sync", "a shared branch keeps Sync")
	expect(Actions.run_action(&"sync.sync", button), "Sync runs on the rewritten main")
	expect(await wait_until(func() -> bool: return "Force push…" in toasts.fix_labels()),
			"the toast offers Force push: %s" % [toasts.fix_labels()])
	expect("Pull and rebase" in toasts.fix_labels() and "Pull and merge" in toasts.fix_labels(),
			"merge and rebase stay offered")
	expect(toasts.toast_texts().has("You rewrote pushed commits on main"), "the toast says why: %s" % [toasts.toast_texts()])
	expect(toasts.press_fix("Force push…"), "Force push can be pressed")
	await _confirm_force_push(ops, session)

	# On a branch of your own, the button itself becomes Force push.
	_git(repo, ["switch", "--quiet", "-c", "topic/amend"])
	session.refresh()
	expect(await wait_until(func() -> bool: return button.text == "Publish branch"), "the new branch can be published")
	await _commit_and_push(repo, session, button, "topic.txt")
	expect(await wait_until(func() -> bool: return button.text == "Fetch" and not button.is_busy()),
			"the topic branch is published: %s" % button.text)
	_git(repo, ["commit", "--amend", "--quiet", "-m", "topic work, amended"])
	session.refresh()
	expect(await wait_until(func() -> bool: return button.text == "Force push"),
			"an amended pushed commit makes Sync a force push: %s" % button.text)
	expect(button.counts().ahead == 1 and button.counts().behind == 1, "the counts stay on the button")
	expect(button.tooltip_text.begins_with("You rewrote 1 pushed commit."), "the tooltip says why: %s" % button.tooltip_text)
	expect(Actions.run_action(&"sync.sync", button), "Sync runs the force push")
	await _confirm_force_push(ops, session)
	expect(await wait_until(func() -> bool: return button.text == "Fetch" and not button.is_busy()),
			"nothing left to sync: %s" % button.text)
	_git(repo, ["switch", "--quiet", "main"])
	session.refresh()
	expect(await wait_until(func() -> bool: return session.current_branch() == "main" and _head_ref(session) == "main"),
			"back on main")

	# The palette lists branches to check out.
	press("Ctrl+K")
	var palette: CommandPalette = main.palette()
	expect(await wait_until(func() -> bool: return palette.visible), "Ctrl+K opens the palette")
	expect("Check out: feature/login" in palette.visible_labels(), "branches are in the palette: %s" % [palette.visible_labels()])
	expect(not ("Check out: main" in palette.visible_labels()), "the checked-out branch is not")
	palette.close()

	# The smoke config's terminal does not exist: a toast says so.
	var before: int = toasts.toast_count()
	press("Ctrl+Shift+T")
	expect(await wait_until(func() -> bool: return toasts.toast_count() > before), "a missing terminal is reported")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Commits `file` outside the app, then pushes (or publishes) it with Sync.
func _commit_and_push(repo: String, session: RepoSession, button: BigButton, file: String) -> void:
	write_file(repo.path_join(file), "work\n")
	_git(repo, ["add", "--", file])
	_git(repo, ["commit", "--quiet", "-m", "work in %s" % file])
	session.refresh()
	expect(await wait_until(func() -> bool: return _ahead(session) == 1 and button.text in ["Push", "Publish branch"]),
			"the commit is ready to push: %s" % button.text)
	expect(Actions.run_action(&"sync.sync", button), "Sync pushes it")


## Accepts the force push confirmation, which names the rewrite, and waits
## for the push.
func _confirm_force_push(ops: RepoOps, session: RepoSession) -> void:
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "Force push asks first")
	expect(confirm.dialog_text.begins_with("Replace the old versions of your commits on origin/"),
			"the confirmation names the rewrite: %s" % confirm.dialog_text)
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return _ahead(session) == 0 and _behind(session) == 0),
			"force pushed: ahead %d, behind %d" % [_ahead(session), _behind(session)])
	expect_eq(_git(session.repo_path(), ["rev-parse", "HEAD"]), _git(session.repo_path(), ["rev-parse", "@{upstream}"]),
			"the remote has the rewritten commit")


static func _git(repo: String, args: PackedStringArray) -> String:
	var output: Array = []
	OS.execute("git", PackedStringArray(["-C", repo]) + args, output, true)
	return String(output[0]).strip_edges() if not output.is_empty() else ""


## The local branch the refs mark as checked out, or "".
static func _head_ref(session: RepoSession) -> String:
	for ref: Dictionary in session.branch_refs():
		if bool(ref.get("is_head", false)) and String(ref.get("kind", "")) == "branch":
			return String(ref["short_name"])
	return ""


static func _ahead(session: RepoSession) -> int:
	return int(session.badge().get("ahead", -1))


static func _behind(session: RepoSession) -> int:
	return int(session.badge().get("behind", -1))
