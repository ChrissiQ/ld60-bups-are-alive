extends SceneTree
## The windowed part of the thumbnails' atlas the world publishes for the dish strip, on the real pool: a dish of bups in the
## main view and a bare dish parked (Dish.park, as Main parks every dish out of the view), the main view's dish asking for thumbnails as the
## screen asks while the strip shows (Dish.want_thumbnails), and the atlas taken each frame as the strip takes it (a ThumbAtlas ticked, its
## texture drawn from: it tells the world which atlas it used); the atlas read on the sim thread (SimCore's THUMBS, what its publish copies
## into the shared texture). Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_thumbs_test.gd
##
## Expected values, written before the run [derived unless marked]:
## A  The atlas made from the pool as it is now (its publish's three kernels, run on the sim thread): the tile of the dish with 2,000 or
##    more bups (its core row's: THUMB_TILE texels square, THUMB_ATLAS / THUMB_TILE tiles a row) has texels with alpha above 0, at least
##    one at 255 (the tile's densest texel); the bare dish's tile is all zero.
## C  Over about 5.5 s of real time with thumbnails wanted, an atlas is made at most once a real second (SimThread.THUMBS_MSEC, whatever
##    the simulation's speed: run at x1,000 here): 5 or 6 of them, and the ThumbAtlas takes each (5 or 6 versions). A thumbnail texture
##    is written again only once the main side has told a newer one used (SimCore._free_texture); there are SimCore.TEXTURES of them and
##    the ThumbAtlas tells each use, so none is ever wanting.

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
	bare.park()
	g.look_at(full, 0.03)
	full.want_thumbnails = true
	await g.wait_picture(full)
	var strip := ThumbAtlas.new()
	var thread: Variant = g.world.backend.get("thread")
	var made := {}
	var taken := {}
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5500:
		await g.frame(1000.0, false)
		strip.tick(g.world)
		strip.texture()
		made[int(thread._thumbs_msec)] = true
		taken[strip.version()] = true
	made.erase(-1000000)
	taken.erase(0)
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
	TestUtil.show(made.size() >= 5 and made.size() <= 6 and taken.size() >= 5 and taken.size() <= 6, "C %d atlases in 5.5 s of real time at x1,000 (at most one a second), %d taken by the strip's ThumbAtlas" % [made.size(), taken.size()])
	strip.release()
	TestUtil.finish(self, "OK parity_thumbs_test")
