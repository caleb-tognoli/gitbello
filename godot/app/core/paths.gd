class_name Paths
extends RefCounted
## Comparing folder paths as git and users write them (slashes, a trailing
## separator, and case on Windows).


static func same(a: String, b: String) -> bool:
	return normalized(a) == normalized(b)


static func normalized(path: String) -> String:
	var slashed: String = path.replace("\\", "/").trim_suffix("/")
	return slashed.to_lower() if OS.has_feature("windows") else slashed
