class_name Paths
extends RefCounted
## Comparing folder paths as git and users write them (slashes, a trailing
## separator, and case on Windows).


static func same(a: String, b: String) -> bool:
	return normalized(a) == normalized(b)


## `path` relative to folder `base`, with forward slashes, or "" when it is
## not inside `base`.
static func relative(path: String, base: String) -> String:
	var prefix: String = normalized(base) + "/"
	if not normalized(path).begins_with(prefix):
		return ""
	return path.replace("\\", "/").substr(prefix.length())


## `path` to show the user: forward slashes, the home folder as `~`.
static func shown(path: String) -> String:
	var home: String = OS.get_environment("USERPROFILE" if OS.has_feature("windows") else "HOME")
	var inside: String = relative(path, home) if not home.is_empty() else ""
	return "~/" + inside if not inside.is_empty() else path.replace("\\", "/")


static func normalized(path: String) -> String:
	var slashed: String = path.replace("\\", "/").trim_suffix("/")
	return slashed.to_lower() if OS.has_feature("windows") else slashed
