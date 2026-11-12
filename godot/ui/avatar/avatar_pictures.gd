class_name AvatarPictures
extends RefCounted
## Profile pictures for `AvatarPainter` (M7.10): asked of the core once per
## email (`RepoSession.request_avatar`, which reads its cache and looks them
## up in the background), then kept as round textures. Until one arrives,
## and when there is none or Settings → Interface → "Show profile pictures"
## is off, avatars are initials. `changed` says when to redraw.

## A picture arrived or went away; "" when they all did (the setting changed).
signal changed(email: String)

## Side of the round texture, in pixels: the details' 30 px avatar on a 2x
## screen, with mipmaps for the smaller ones.
const SIZE: int = 64
## The circle is cut at this many times `SIZE`, then halved down, for a
## smooth edge.
const SUPERSAMPLE: int = 4
## An email without a picture is asked again after this long (the core
## looks up again a lookup that could not finish, offline for one).
const RETRY_MSEC: int = 5 * 60 * 1000
## The providers Settings → Interface → Picture sources turns on and off,
## as the core names them, and their names on screen.
const PROVIDERS: Array = ["github", "gitlab", "gravatar", "libravatar"]
const PROVIDER_NAMES: Array = ["GitHub", "GitLab", "Gravatar", "Libravatar"]

static var _shared: AvatarPictures = null
static var _mask: Image = null

var _enabled: bool = true
## Normalized email -> its round picture.
var _textures: Dictionary[String, Texture2D] = {}
## Session id and normalized email -> when that session last asked for it
## (`Time.get_ticks_msec`).
var _requested: Dictionary[String, int] = {}


static func shared() -> AvatarPictures:
	if _shared == null:
		_shared = AvatarPictures.new()
		# Static references outlive the scene tree; drop them with the app.
		Core.tree_exiting.connect(AvatarPictures._release, CONNECT_ONE_SHOT)
	return _shared


static func _release() -> void:
	_shared = null
	_mask = null


## The email as the core keys it: trimmed, lowercase.
static func normalize(email: String) -> String:
	return email.strip_edges().to_lower()


func _init() -> void:
	_enabled = bool(Core.settings().get("avatars", true))
	Core.avatar_changed.connect(_on_avatar_changed)


func is_enabled() -> bool:
	return _enabled


## Follows the setting (already saved): off drops every picture.
func set_enabled(enabled: bool) -> void:
	if enabled == _enabled:
		return
	_enabled = enabled
	reset()


## Forgets every picture and asks again (the providers changed).
func reset() -> void:
	_textures.clear()
	_requested.clear()
	changed.emit("")


## `email`'s picture, or null (draw initials). The first call with each
## `session` asks for it, through that repository's remotes (the core asks
## the sources once, and again from a repository on GitHub when that may
## find one).
func texture(email: String, session: RepoSession = null) -> Texture2D:
	if not _enabled:
		return null
	var key: String = normalize(email)
	if key.is_empty():
		return null
	var found: Texture2D = _textures.get(key, null) as Texture2D
	if found == null and session != null:
		var now: int = Time.get_ticks_msec()
		var asked: String = "%d %s" % [session.get_instance_id(), key]
		if not _requested.has(asked) or now - _requested[asked] >= RETRY_MSEC:
			_requested[asked] = now
			session.request_avatar(key)
	return found


## Number of pictures held, for smoke tests.
func count() -> int:
	return _textures.size()


func _on_avatar_changed(email: String) -> void:
	if not _enabled:
		return
	var picture: Dictionary = Core.avatar(email)
	var made: Texture2D = null
	if not picture.is_empty():
		made = round_texture(picture["bytes"] as PackedByteArray, String(picture["format"]))
	if made != null:
		_textures[email] = made
	else:
		_textures.erase(email)
	changed.emit(email)


## The image file `bytes` (`format` "png", "jpg" or "webp") cut to a
## circle, `SIZE` wide, or null when it does not load.
static func round_texture(bytes: PackedByteArray, format: String) -> Texture2D:
	var image: Image = Image.new()
	var error: Error = ERR_FILE_UNRECOGNIZED
	match format:
		"png":
			error = image.load_png_from_buffer(bytes)
		"jpg":
			error = image.load_jpg_from_buffer(bytes)
		"webp":
			error = image.load_webp_from_buffer(bytes)
	if error != OK or image.is_empty():
		return null
	image.convert(Image.FORMAT_RGBA8)
	var width: int = image.get_width()
	var height: int = image.get_height()
	if width != height:
		var side: int = mini(width, height)
		image = image.get_region(Rect2i(floori((width - side) * 0.5), floori((height - side) * 0.5), side, side))
	var big: int = SIZE * SUPERSAMPLE
	image.resize(big, big, Image.INTERPOLATE_LANCZOS)
	var circle: Image = Image.create_empty(big, big, false, Image.FORMAT_RGBA8)
	circle.blit_rect_mask(image, _circle_mask(), Rect2i(0, 0, big, big), Vector2i.ZERO)
	# Halving averages the cut edge into a smooth one.
	while circle.get_width() > SIZE:
		var half: int = floori(circle.get_width() * 0.5)
		circle.resize(half, half, Image.INTERPOLATE_BILINEAR)
	circle.generate_mipmaps()
	var result: CanvasTexture = CanvasTexture.new()
	result.diffuse_texture = ImageTexture.create_from_image(circle)
	result.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return result


## A filled circle as wide as the supersampled picture, for `blit_rect_mask`.
static func _circle_mask() -> Image:
	if _mask != null:
		return _mask
	var big: int = SIZE * SUPERSAMPLE
	_mask = Image.create_empty(big, big, false, Image.FORMAT_RGBA8)
	var radius: float = big * 0.5
	for y: int in big:
		var dy: float = y + 0.5 - radius
		var half: float = sqrt(maxf(0.0, radius * radius - dy * dy))
		var start: int = roundi(radius - half)
		var end: int = roundi(radius + half)
		if end > start:
			_mask.fill_rect(Rect2i(start, y, end - start, 1), Color.WHITE)
	return _mask
