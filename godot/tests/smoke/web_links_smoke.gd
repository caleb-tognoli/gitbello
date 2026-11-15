extends SmokeTest
## Copy ▸ and Open on <host> on fixture `history`, given an `origin`
## on github.com that is never contacted (its tracking ref is made locally):
## the commit's Copy entries, Open on GitHub for a commit, a pushed branch, a
## tag and a file, hidden for a branch never pushed. Skipped without
## `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("web_links_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("history")
	_git(repo, ["remote", "add", "origin", "https://github.com/owner/repo.git"])
	_git(repo, ["update-ref", "refs/remotes/origin/main", "main"])
	_git(repo, ["branch", "--set-upstream-to=origin/main", "main"])
	_git(repo, ["tag", "v1", "main"])

	var copied: Array[String] = [""]
	var real_clipboard: Callable = Main.clipboard
	Main.clipboard = func(text: String) -> void: copied[0] = text
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.ref_web_page("refs/heads/main").has("url")),
			"main has a page once the refs are read")
	var base: String = "https://github.com/owner/repo"
	expect_eq(session.ref_web_page("refs/heads/main"), {"host": "GitHub", "url": base + "/tree/main"},
			"a pushed branch opens its tree")
	expect(session.ref_web_page("refs/heads/topic").is_empty(), "a branch never pushed has no page")

	# The commit menu: Copy ▸ and Open on GitHub.
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() > 0), "the history lists commits")
	list.grab_focus()
	list.select_only(0)
	var oid: String = list.hash_at(0)
	expect(await wait_until(func() -> bool: return String(session.commit_info().get("oid", "")) == oid),
			"the selected commit loads")
	history.commit_menu_requested.emit(Vector2.ZERO)
	var ids: Array[StringName] = page.menu_ids()
	for id: StringName in [&"commit.copy_hash", &"commit.copy_short_hash", &"commit.copy_subject",
			&"commit.copy_message", &"commit.open_web"]:
		expect(id in ids, "the commit menu has %s: %s" % [id, ids])
	expect(tr("Open on %s") % "GitHub" in page.menu_labels(), "it names the host: %s" % [page.menu_labels()])
	expect(page.press_menu_id(&"commit.copy_message"), "Copy ▸ Message runs")
	var info: Dictionary = session.commit_info()
	expect(copied[0].begins_with(String(info["summary"])),
			"the message starts with the subject: %s" % copied[0])
	history.commit_menu_requested.emit(Vector2.ZERO)
	expect(page.press_menu_id(&"commit.copy_short_hash"), "Copy ▸ Short hash runs")
	expect_eq(copied[0], ShortHash.of(oid), "the short hash is copied")

	# Ref menus: a pushed branch and a tag open on GitHub, a local one does not.
	var main_ref: Dictionary = {"type": "branch", "name": "refs/heads/main", "short": "main", "commit": oid,
		"is_head": true, "upstream": "refs/remotes/origin/main", "worktree": ""}
	page.active_view().show_ref_menu(main_ref, Vector2.ZERO)
	expect(&"branch.open_web" in page.menu_ids() and &"branch.copy_name" in page.menu_ids(),
			"main's menu opens it on GitHub and copies its name: %s" % [page.menu_ids()])
	expect(page.press_menu_id(&"branch.copy_name"), "Copy name runs")
	expect_eq(copied[0], "main", "the branch name is copied")
	var topic: Dictionary = main_ref.duplicate()
	topic.merge({"name": "refs/heads/topic", "short": "topic", "is_head": false, "upstream": ""}, true)
	page.active_view().show_ref_menu(topic, Vector2.ZERO)
	expect(not &"branch.open_web" in page.menu_ids(), "topic was never pushed: %s" % [page.menu_ids()])
	page.close_menu()
	expect_eq(session.ref_web_page("refs/tags/v1")["url"], base + "/releases/tag/v1", "a tag opens its release")

	# A file of the commit: Open on GitHub at that commit.
	expect_eq(session.commit_web_page(oid, "src/login/auth.rs")["url"], "%s/blob/%s/src/login/auth.rs" % [base, oid],
			"a file opens at the commit")

	Main.clipboard = real_clipboard
	_git(repo, ["remote", "remove", "origin"])
	_git(repo, ["tag", "-d", "v1"])
	main.queue_free()
	await get_tree().process_frame


static func _git(repo: String, args: PackedStringArray) -> void:
	OS.execute("git", PackedStringArray(["-C", repo]) + args, [], true)
