extends SceneTree

# Composite member sprites into one atlas sheet from an atlasLayout JSON.
# Run: godot --headless --path tools/godot/ --script res://atlas_render.gd -- <layout.json> <sprite_dir> <out_sheet.png>
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("atlas_render: usage: -- <layout.json> <sprite_dir> <out_sheet.png>")
		quit(1)
		return
	var layout_path := args[0]
	var sprite_dir := args[1]
	var out_path := args[2]

	var txt := FileAccess.get_file_as_string(layout_path)
	if txt == "":
		push_error("atlas_render: could not read layout %s" % layout_path)
		quit(1)
		return
	var data = JSON.parse_string(txt)
	if data == null or not data.has("sheet") or not data.has("placements"):
		push_error("atlas_render: layout JSON missing sheet/placements")
		quit(1)
		return

	var sheet_w := int(data["sheet"]["w"])
	var sheet_h := int(data["sheet"]["h"])
	var target := Image.create(sheet_w, sheet_h, false, Image.FORMAT_RGBA8)
	target.fill(Color(0, 0, 0, 0))

	for p in data["placements"]:
		var src := Image.load_from_file(sprite_dir.path_join(str(p["name"]) + ".png"))
		if src == null:
			push_error("atlas_render: failed to load sprite %s" % str(p["name"]))
			quit(1)
			return
		if src.get_format() != Image.FORMAT_RGBA8:
			src.convert(Image.FORMAT_RGBA8)
		target.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i(int(p["x"]), int(p["y"])))

	var serr := target.save_png(out_path)
	if serr != OK:
		push_error("atlas_render: failed to save %s (err %d)" % [out_path, serr])
		quit(1)
		return
	print("ATLAS_RENDER OK")
	quit(0)
