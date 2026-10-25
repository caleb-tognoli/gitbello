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


static func normalized(path: String) -> String:
	var slashed: String = path.replace("\\", "/").trim_suffix("/")
	return slashed.to_lower() if OS.has_feature("windows") else slashed
