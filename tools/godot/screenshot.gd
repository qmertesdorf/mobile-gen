extends SceneTree

# Capture a gameplay frame at a target size. Must run on the REAL renderer
# (NOT --headless -- the dummy renderer cannot capture pixels).
# package.mjs copies this into games/<id>/ as res://_screenshot.gd and runs:
#   godot --path games/<id>/ --script res://_screenshot.gd -- <out.png> <frames>
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1:
		push_error("screenshot: usage: -- <out.png> [frames]")
		quit(1)
		return
	var out_path := args[0]
	var frames := int(args[1]) if args.size() > 1 else 220

	var packed := load("res://Main.tscn")
	if packed == null:
		push_error("screenshot: could not load res://Main.tscn")
		quit(1)
		return
	get_root().add_child(packed.instantiate())
	_capture(out_path, frames)

func _capture(out_path: String, frames: int) -> void:
	for _i in range(frames):
		await process_frame
	var img := get_root().get_texture().get_image()
	var serr := img.save_png(out_path)
	if serr != OK:
		push_error("screenshot: failed to save %s (err %d)" % [out_path, serr])
		quit(1)
		return
	print("SCREENSHOT OK")
	quit(0)
