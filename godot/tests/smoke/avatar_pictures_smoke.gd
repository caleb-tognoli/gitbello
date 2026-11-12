extends SmokeTest
## M7.10: profile pictures. A picture is cut to a round texture; one seeded
## in the scratch cache shows in an avatar asked through a session (no
## network: the smoke run points every source at a closed local port), and
## "Show profile pictures" off brings back initials until it is on again;
## so does turning off the provider the picture came from (Picture sources).
## Read-only on the fixture `repo-1`; the views are skipped without
## `--fixtures`.

## An email no other smoke test draws, so nothing asked for it before.
const EMAIL: String = " Avatar.Smoke@Example.com"


func run() -> void:
	_check_round_texture()
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("avatar_pictures_smoke: no --fixtures, skipped the views")
		return
	var cache: String = OS.get_environment("GITBELLO_CACHE_DIR")
	expect(not cache.is_empty(), "the smoke run has a scratch cache")
	if cache.is_empty():
		return
	var key: String = AvatarPictures.normalize(EMAIL)
	expect_eq(key, "avatar.smoke@example.com", "emails are trimmed and lowercased")
	var folder: String = cache.path_join("avatars")
	DirAccess.make_dir_recursive_absolute(folder)
	var file: FileAccess = FileAccess.open(folder.path_join(key.sha256_text() + ".gravatar.png"), FileAccess.WRITE)
	file.store_buffer(_png(Color(0.9, 0.5, 0.1), 40, 40))
	file.close()

	var session: RepoSession = Core.open_session(fixtures.path_join("repo-1"))
	add_child(session)
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opens")
	var pictures: AvatarPictures = AvatarPictures.shared()
	var view: AvatarView = AvatarView.new("Avatar Smoke", EMAIL, 30.0)
	add_child(view)
	await get_tree().process_frame
	expect(pictures.texture(EMAIL) == null, "without a session nothing is asked")
	view.session = session
	expect(await wait_until(func() -> bool: return pictures.texture(EMAIL) != null),
			"the cached picture arrives")
	var picture: Texture2D = pictures.texture(EMAIL)
	if picture != null:
		expect_eq(picture.get_size(), Vector2(AvatarPictures.SIZE, AvatarPictures.SIZE), "it is cut to its size")

	# Off: initials, and nothing kept; on again it comes back from the cache.
	expect_eq(Core.set_settings({"avatars": false}), "", "Show profile pictures saves")
	pictures.set_enabled(false)
	expect(not bool(Core.settings()["avatars"]), "the setting reads back off")
	expect(pictures.texture(EMAIL, session) == null and pictures.count() == 0, "off draws initials")
	expect_eq(Core.set_settings({"avatars": true}), "", "turning it on saves")
	pictures.set_enabled(true)
	view.queue_redraw()
	expect(await wait_until(func() -> bool: return pictures.texture(EMAIL) != null),
			"on again the picture comes back")

	# Its provider off: initials (no other source answers here); on again, back.
	var all: Array = AvatarPictures.PROVIDERS.duplicate()
	expect_eq(Array(Core.settings()["avatar_providers"] as PackedStringArray), all, "every provider is on")
	var without: Array = all.filter(func(provider: String) -> bool: return provider != "gravatar")
	expect_eq(Core.set_settings({"avatar_providers": without}), "", "Picture sources saves")
	expect_eq(Array(Core.settings()["avatar_providers"] as PackedStringArray), without, "it reads back")
	pictures.reset()
	view.queue_redraw()
	for i: int in 20:
		await get_tree().process_frame
	expect(pictures.texture(EMAIL) == null, "a picture from a provider turned off is hidden")
	expect(Core.set_settings({"avatar_providers": ["gitlab", "nope"]}) != "", "unknown providers are refused")
	expect_eq(Core.set_settings({"avatar_providers": all}), "", "every provider on again")
	pictures.reset()
	view.queue_redraw()
	expect(await wait_until(func() -> bool: return pictures.texture(EMAIL) != null),
			"its provider on again, the picture comes back")
	view.queue_free()
	Core.close_session(session)


func _check_round_texture() -> void:
	var texture: Texture2D = AvatarPictures.round_texture(_png(Color.RED, 50, 30), "png")
	expect(texture != null, "a PNG loads")
	if texture == null:
		return
	expect_eq(texture.get_size(), Vector2(AvatarPictures.SIZE, AvatarPictures.SIZE), "a wide picture is cropped square")
	var image: Image = (texture as CanvasTexture).diffuse_texture.get_image()
	var last: int = AvatarPictures.SIZE - 1
	var middle: int = floori(AvatarPictures.SIZE * 0.5)
	expect(image.get_pixel(0, 0).a < 0.01 and image.get_pixel(last, last).a < 0.01, "the corners are clear")
	var center: Color = image.get_pixel(middle, middle)
	expect(center.a > 0.99 and center.r > 0.9, "the middle is the picture: %s" % center)
	var smoothed: bool = false
	for i: int in middle:
		var alpha: float = image.get_pixel(i, i).a
		smoothed = smoothed or (alpha > 0.05 and alpha < 0.95)
	expect(smoothed, "the edge is smoothed")
	var jpeg: Image = Image.create_empty(20, 20, false, Image.FORMAT_RGB8)
	jpeg.fill(Color.BLUE)
	expect(AvatarPictures.round_texture(jpeg.save_jpg_to_buffer(), "jpg") != null, "a JPEG loads")
	expect(AvatarPictures.round_texture(jpeg.save_png_to_buffer(), "gif") == null, "another format gives initials")


func _png(color: Color, width: int, height: int) -> PackedByteArray:
	var image: Image = Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image.save_png_to_buffer()
