extends SceneTree
## Its windowed part (the thumbnails' atlas the world publishes for the dish strip) on the real pool: a dish of bups and a
## bare dish at ParityGame.PLACE, the main view asking for thumbnails as the strip will (ViewRequest.want_thumbnails; the strip itself is
## another script's), the atlas read on the sim thread (SimCore's THUMBS, what its publish copies into the shared texture). Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_thumbs_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## A  The atlas made from the pool as it is now (its publish's three kernels, run on the sim thread: the publish itself writes it only when
##    a thumbnail texture is free, see C): the tile of the dish with 2,000 or more bups (its core row's: THUMB_TILE texels square, THUMB_ATLAS / THUMB_TILE tiles a row) has texels
##    with alpha above 0, at least one at 255 (the tile's densest texel); the bare dish's tile is all zero.
## C  Over about 5.5 s of real time with thumbnails wanted, an atlas is made at most once a real second (SimThread.THUMBS_MSEC, whatever
##    the simulation's speed: run at x1,000 here): 5 or 6 of them. [derived risk: a thumbnail texture is written again only once the main
##    side has told it used (SimCore._free_texture), and nothing on the main side binds them yet: then only the first
##    publishes come; that is reported as a failure of the row's cadence, not passed.]

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_thumbs_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_thumbs_test")
		return
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 10000.0
	spec.limit = 20000
	spec.seed = 4
	spec.founders = Scenario.small(2000, 10000.0).seed(4).founder_records(1)
	var full: Dish = await g.add(spec)
	var bare_spec := DishSpec.new()
	bare_spec.number = 2
	bare_spec.radius = 10000.0
	bare_spec.limit = 1000
	bare_spec.seed = 5
	var bare: Dish = await g.add(bare_spec)
	bare.picture_scale = 0.1  # (out of the main view: its node draws nothing of its own)
	g.look_at(full, 0.03)
	await g.wait_picture(full)
	var v := ViewRequest.new()
	v.camera = Rect2(-10000.0, -10000.0, 20000.0, 20000.0)
	v.pixel_um = 1.0 / 0.03
	v.want_thumbnails = true
	g.world.set_view(full.row, v)
	var thread: Variant = g.world.backend.get("thread")
	var made := {}
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5500:
		await g.frame(1000.0, false)
		made[int(thread._thumbs_msec)] = true
	made.erase(-1000000)
	await g.settle()
	var rows := [full.row, bare.row]
	var tiles: Array = await g.inspect(func(core: SimCore, map: Dictionary) -> Array:
		var size := GpuKernelsDraw.THUMB_ATLAS
		var tiles_n := GpuLayout.D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE
		core._run_list(func(cl: int) -> void:
			core._disp(cl, "pool_thumb_clear", SimCore._groups(tiles_n))
			core._disp(cl, "pool_thumb_splat", core._bup_groups())
			core._disp(cl, "pool_thumb_resolve", SimCore._groups(tiles_n)), false)
		var atlas: PackedByteArray = core.read_parts([["THUMBS", 0, size * size * 4]])[0]
		var out: Array = []
		for r: int in rows:
			var cr: int = map.get(r, -1)
			var lit := 0
			var full_alpha := 0
			var per_row := size / GpuKernelsDraw.THUMB_TILE
			var ox := (cr % per_row) * GpuKernelsDraw.THUMB_TILE
			var oy := (cr / per_row) * GpuKernelsDraw.THUMB_TILE
			for y in GpuKernelsDraw.THUMB_TILE:
				for x in GpuKernelsDraw.THUMB_TILE:
					var a := atlas[((oy + y) * size + ox + x) * 4 + 3]
					lit += 1 if a > 0 else 0
					full_alpha += 1 if a == 255 else 0
			out.append([cr, lit, full_alpha])
		return out)
	TestUtil.show(tiles[0][1] > 0 and tiles[0][2] >= 1 and tiles[1][1] == 0, "A the tile of the dish with %d bups (row %d) has %d texels lit, %d at full alpha; the bare dish's (row %d) %d lit" % [full.population(), tiles[0][0], tiles[0][1], tiles[0][2], tiles[1][0], tiles[1][1]])
	TestUtil.show(made.size() >= 5 and made.size() <= 6, "C %d atlases in 5.5 s of real time at x1,000 (at most one a second)" % made.size())
	TestUtil.finish(self, "OK parity_thumbs_test")
