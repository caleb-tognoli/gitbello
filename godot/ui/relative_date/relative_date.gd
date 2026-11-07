class_name RelativeDate
extends RefCounted
## Commit dates as History shows them (M7.10): relative up to 30 days
## ("3 h ago", "12 days ago"), then a short date this year ("Mar 4"), then
## `YYYY-MM-DD`. `exact` is the full local time for tooltips.

const MONTHS: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
		"Sep", "Oct", "Nov", "Dec"]
## Days shown as "N days ago" before the date takes over.
const RELATIVE_DAYS: int = 30


## `when` relative to `now` (unix seconds; local time for the dates).
static func text(when: int, now: int, utc_offset: int) -> String:
	var seconds: int = now - when
	if seconds < 0:
		# Clock skew or a future author date: show the date itself.
		return _date(when, now, utc_offset)
	if seconds < 60:
		return TranslationServer.translate("just now")
	if seconds < 3600:
		return TranslationServer.translate("%d min ago") % floori(seconds / 60.0)
	if seconds < 86400:
		return TranslationServer.translate("%d h ago") % floori(seconds / 3600.0)
	var days: int = floori(seconds / 86400.0)
	if days == 1:
		return TranslationServer.translate("yesterday")
	if days < RELATIVE_DAYS:
		return TranslationServer.translate("%d days ago") % days
	return _date(when, now, utc_offset)


## `YYYY-MM-DD HH:MM` in local time.
static func exact(when: int, utc_offset: int) -> String:
	return Time.get_datetime_string_from_unix_time(when + utc_offset, true).left(16)


## The system's offset from UTC, in seconds.
static func local_offset() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


static func _date(when: int, now: int, utc_offset: int) -> String:
	var date: Dictionary = Time.get_date_dict_from_unix_time(when + utc_offset)
	var today: Dictionary = Time.get_date_dict_from_unix_time(now + utc_offset)
	if int(date["year"]) != int(today["year"]):
		return Time.get_date_string_from_unix_time(when + utc_offset)
	var month: String = TranslationServer.translate(MONTHS[int(date["month"]) - 1])
	return TranslationServer.translate("{month} {day}").format({"month": month, "day": int(date["day"])})
