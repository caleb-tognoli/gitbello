extends SmokeTest
## The branch list's sections (`BranchPopover.sections`) on made-up refs:
## Recent holds the current branch and the ones last checked out, and they are
## not listed again; small lists have no Recent; Remote lists only the remote
## branches no local branch tracks (merging: the current branch's upstream
## first). Also `BranchNameLayer.split`. No repository.


func run() -> void:
	expect_eq(BranchNameLayer.split("feature/team/login"), PackedStringArray(["feature/team/", "login"]),
			"the prefix ends at the last slash")
	expect_eq(BranchNameLayer.split("main"), PackedStringArray(["", "main"]), "a name without a slash has no prefix")

	# Seven local branches, five checked out at some point.
	var refs: Array[Dictionary] = [
		_ref("main", true, "origin/main", 100),
		_ref("chore/deps", false, "", 0),
		_ref("Feature/b", false, "origin/feature/b", 600),
		_ref("feature/a", false, "", 500),
		_ref("fix/crash", false, "", 400),
		_ref("login", false, "", 300),
		_ref("old", false, "", 200),
		_ref("zeta", false, "", 0),
		_remote("origin/main"),
		_remote("origin/feature/b"),
		# Not tracked: a local `login` no longer hides it (only tracking does).
		_remote("origin/feature/login"),
		_remote("origin/Release"),
		_remote("upstream/main"),
	]
	var sections: Array = BranchPopover.sections(refs, false)
	expect_eq(_titles(sections), PackedStringArray(["Recent", "Local", "Remote"]), "a long list has Recent")
	expect_eq(_names(sections[0]), PackedStringArray(["main", "Feature/b", "feature/a", "fix/crash", "login"]),
			"Recent: the current branch, then the last checked out, five rows")
	expect_eq(_names(sections[1]), PackedStringArray(["chore/deps", "old", "zeta"]),
			"Local: the rest A–Z, without Recent's branches")
	expect_eq(_names(sections[2]), PackedStringArray(["origin/feature/login", "origin/Release", "upstream/main"]),
			"Remote: untracked remote branches A–Z")

	var merging: Array = BranchPopover.sections(refs, true)
	expect_eq(_names(merging[0]), PackedStringArray(["Feature/b", "feature/a", "fix/crash", "login", "old"]),
			"merging: Recent leaves out the current branch and holds five others")
	expect_eq(_names(merging[1]), PackedStringArray(["chore/deps", "zeta"]), "merging: the rest")
	expect_eq(_names(merging[2]),
			PackedStringArray(["origin/main", "origin/feature/login", "origin/Release", "upstream/main"]),
			"merging: the current branch's upstream comes first in Remote")

	# Nothing checked out but the current branch: no one-row Recent.
	var fresh: Array[Dictionary] = []
	for ref: Dictionary in refs:
		var copy: Dictionary = ref.duplicate()
		if not bool(copy["is_head"]):
			copy["checked_out_at"] = 0
		fresh.append(copy)
	var plain: Array = BranchPopover.sections(fresh, false)
	expect_eq(_titles(plain), PackedStringArray(["", "Remote"]), "no Recent without other checkouts")
	expect_eq(_names(plain[0]),
			PackedStringArray(["main", "chore/deps", "feature/a", "Feature/b", "fix/crash", "login", "old", "zeta"]),
			"the current branch first, then A–Z")

	# Five local branches or fewer: one list, current first.
	var small: Array[Dictionary] = [_ref("zeta", false, "", 50), _ref("main", true, "", 10), _ref("alpha", false, "", 40)]
	var short: Array = BranchPopover.sections(small, false)
	expect_eq(_titles(short), PackedStringArray(["", "Remote"]), "a short list has no Recent")
	expect_eq(_names(short[0]), PackedStringArray(["main", "alpha", "zeta"]), "a short list: current, then A–Z")


func _ref(branch: String, head: bool, upstream: String, checked_out_at: int) -> Dictionary:
	return {"kind": "branch", "short_name": branch, "is_head": head, "upstream": upstream,
			"checked_out_at": checked_out_at}


func _remote(branch: String) -> Dictionary:
	return {"kind": "remote", "short_name": branch, "is_head": false, "upstream": "", "checked_out_at": 0}


func _titles(sections: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for section: Array in sections:
		out.append(String(section[0]))
	return out


func _names(section: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ref: Dictionary in section[1]:
		out.append(String(ref["short_name"]))
	return out
