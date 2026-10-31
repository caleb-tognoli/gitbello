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


## Folder names of `paths` for a short list (Recent): a name shared with
## another entry gets as many parent folders as tell them apart
## ("gitbello · Work/clients"), with the drive or server when needed.
static func short_labels(paths: PackedStringArray) -> PackedStringArray:
	var labels: PackedStringArray = PackedStringArray()
	for i: int in paths.size():
		var name: String = folder_name(paths[i])
		var peers: PackedStringArray = PackedStringArray()
		for j: int in paths.size():
			if i != j and same(name, folder_name(paths[j])):
				peers.append(paths[j])
		if peers.is_empty():
			labels.append(name)
			continue
		var depth: int = 1
		var context: String = _parent_suffix(paths[i], depth)
		while true:
			var ambiguous: bool = false
			for peer: String in peers:
				if same(context, _parent_suffix(peer, depth)):
					ambiguous = true
					break
			var longer: String = _parent_suffix(paths[i], depth + 1)
			if not ambiguous or context == longer:
				break
			depth += 1
			context = longer
		labels.append("%s · %s" % [name, context])
	return labels


## The last folder of `path` ("/" for the root).
static func folder_name(path: String) -> String:
	var slashed: String = path.replace("\\", "/").rstrip("/")
	return slashed.get_file() if not slashed.is_empty() else "/"


## The last `depth` parent folders of `path`, keeping a drive or server
## when they are all there is.
static func _parent_suffix(path: String, depth: int) -> String:
	var parent: String = path.replace("\\", "/").rstrip("/").get_base_dir()
	var parts: PackedStringArray = parent.split("/", false)
	if parts.is_empty():
		return "/"
	if parent.ends_with(":"):
		return parent + "/"
	var suffix: String = "/".join(parts.slice(maxi(0, parts.size() - depth)))
	return "//" + suffix if parent.begins_with("//") and depth >= parts.size() else suffix
