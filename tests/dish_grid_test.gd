extends SceneTree
## The landscape's value in a cell is the one the lattice formula gives by hashing the four corners of the cell's lattice square in each octave
## (the octaves from the dish's width down to the cell spacing, each weighing 0.8 of the one before): the grid reads them from a table of
## corners made once, so it must equal that formula to the last bit in every cell, for the sizes a dish has (small, 100 cells across, a big
## dish, a corner on either side of zero).


func _initialize() -> void:
	for c: Array in [[300.0, 48, 0.5, 1000], [1500.0, 100, 0.3, 123456789], [22500.0, 100, 0.8, 99], [20.0, 12, 0.5, 5], [600.0, 64, 2.0, -5]]:
		var g := DishGrid.make(c[0], c[1], c[2], c[3])
		var worst := 0.0
		var cells := 0
		for y in g.n:
			for x in g.n:
				var cx := (x + 0.5) * g.spacing - g.radius
				var cy := (y + 0.5) * g.spacing - g.radius
				var want := _reference(g, cx, cy)
				worst = maxf(worst, absf(g._patch_noise(x, y) - want))
				cells += 1
		TestUtil.check(worst == 0.0, "dish %s: the %d cells' landscape equals the corner-hash formula exactly (off by at most %s)" % [c, cells, worst])
	TestUtil.finish(self, "DISH GRID TEST OK")


static func _reference(g: DishGrid, x: float, y: float) -> float:
	var total := 0.0
	var strength := 1.0
	var lattice := g._patch_size
	var octave := 0
	while octave < 10 and (octave == 0 or lattice >= g.spacing):
		var seed_v := g._patch_seed + octave * DishGrid.K_OCTAVE
		var gx := x / lattice
		var gy := y / lattice
		var fx := floorf(gx)
		var fy := floorf(gy)
		var tx := gx - fx
		var ty := gy - fy
		tx = tx * tx * (3.0 - 2.0 * tx)
		ty = ty * ty * (3.0 - 2.0 * ty)
		var ix := int(fx)
		var iy := int(fy)
		var c00 := DishGrid._corner(ix, iy, seed_v)
		var c10 := DishGrid._corner(ix + 1, iy, seed_v)
		var c01 := DishGrid._corner(ix, iy + 1, seed_v)
		var c11 := DishGrid._corner(ix + 1, iy + 1, seed_v)
		var top := c00 + (c10 - c00) * tx
		var bottom := c01 + (c11 - c01) * tx
		total += strength * (top + (bottom - top) * ty)
		strength *= 0.8
		lattice *= 0.5
		octave += 1
	return total
