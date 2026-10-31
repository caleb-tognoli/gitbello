extends Node
## Applies the configured UI language. `system` uses Italian for Italian OS
## locales and English for every other locale.

const CHOICES: PackedStringArray = ["system", "en", "it"]


func _ready() -> void:
	apply(String(Core.settings().get("language", "system")))


static func resolved(choice: String, os_locale: String = "") -> String:
	if choice != "system":
		return choice if choice in ["en", "it"] else "en"
	var locale: String = OS.get_locale() if os_locale.is_empty() else os_locale
	return "it" if locale.to_lower().begins_with("it") else "en"


func choice() -> String:
	return String(Core.settings().get("language", "system"))


func apply(value: String) -> void:
	TranslationServer.set_locale(resolved(value))


func set_choice(value: String) -> String:
	if value not in CHOICES:
		return "Unsupported language."
	var error: String = Core.set_settings({"language": value})
	if error.is_empty():
		apply(value)
	return config_error(error)


static func launch_error(error: String) -> String:
	if error == "the command is empty":
		return TranslationServer.translate("The command is empty.")
	if error == "no terminal program found; set `terminal_command` in the settings":
		return TranslationServer.translate("No terminal program was found. Set Terminal in Settings.")
	if error.begins_with("unmatched quote in `") and error.ends_with("`"):
		return TranslationServer.translate("Unmatched quote in `%s`.") % error.trim_prefix("unmatched quote in `").trim_suffix("`")
	if error.begins_with("`") and error.ends_with("` was not found; check the command in the settings"):
		return TranslationServer.translate("`%s` was not found. Check the command in Settings.") % error.trim_prefix("`").trim_suffix("` was not found; check the command in the settings")
	if error.begins_with("cannot start `"):
		var rest: String = error.trim_prefix("cannot start `")
		var separator: int = rest.find("`: ")
		if separator >= 0:
			return TranslationServer.translate("Cannot start `%s`: %s") % [rest.left(separator), rest.substr(separator + 3)]
	return runtime_error(error)


static func runtime_error(error: String) -> String:
	var kinds: PackedStringArray = [
		"git executable not found", "git is older than the supported minimum", "could not start git",
		"I/O error while talking to git", "not a git repository", "authentication failed",
		"rejected: not a fast-forward", "conflict", "another git process holds a lock", "cancelled",
		"unexpected git output", "the file changed since it was shown", "local changes would be overwritten",
		"branches have diverged", "no upstream branch", "no remote configured", "branch is not fully merged",
		"branch is checked out in another worktree", "already exists", "git failed",
	]
	for kind: String in kinds:
		if error == kind:
			return TranslationServer.translate(kind)
		var suffix: String = ": " + kind
		if error.ends_with(suffix):
			return error.trim_suffix(suffix) + ": " + TranslationServer.translate(kind)
	return error


static func config_error(error: String) -> String:
	var prefixes: Dictionary = {
		"cannot read ": "Cannot read %s: %s",
		"cannot write ": "Cannot write %s: %s",
		"cannot watch ": "Cannot watch %s: %s",
		"cannot resolve ": "Cannot resolve %s: %s",
	}
	for prefix: String in prefixes:
		if error.begins_with(prefix):
			var rest: String = error.trim_prefix(prefix)
			var separator: int = rest.rfind(": ")
			if separator >= 0:
				return TranslationServer.translate(String(prefixes[prefix])) % [
					rest.left(separator), rest.substr(separator + 2)]
	if error.begins_with("invalid TOML: "):
		return TranslationServer.translate("Invalid TOML: %s") % error.trim_prefix("invalid TOML: ")
	if error.begins_with("`"):
		var separator: int = error.find("` must be ")
		if separator > 0:
			return TranslationServer.translate("`%s` must be %s") % [
				error.substr(1, separator - 1), TranslationServer.translate(error.substr(separator + 10))]
	return error
