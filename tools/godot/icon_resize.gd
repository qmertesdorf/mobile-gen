extends SceneTree

# Resize a master PNG into N square icon outputs.
# Run: godot --headless --path tools/godot/ --script res://icon_resize.gd -- <master.png> <outdir> <name:px,name:px,...>
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("icon_resize: usage: -- <master.png> <outdir> <name:px,name:px,...>")
		quit(1)
		return
	var master_path := args[0]
	var outdir := args[1]
	var specs := args[2].split(",", false)

	var img := Image.load_from_file(master_path)
	if img == null:
		push_error("icon_resize: failed to load master %s" % master_path)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(outdir)

	for spec in specs:
		var parts := spec.split(":")
		if parts.size() != 2:
			push_error("icon_resize: bad spec '%s' (expected name:px)" % spec)
			quit(1)
			return
		var icon_name := parts[0]
		var px := int(parts[1])
		var copy := img.duplicate() as Image
		copy.resize(px, px, Image.INTERPOLATE_LANCZOS)
		var dest := outdir.path_join(icon_name + ".png")
		var serr := copy.save_png(dest)
		if serr != OK:
			push_error("icon_resize: failed to save %s (err %d)" % [dest, serr])
			quit(1)
			return
		print("icon_resize: wrote %s (%dx%d)" % [dest, px, px])

	print("ICON_RESIZE OK")
	quit(0)
