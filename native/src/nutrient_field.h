#pragma once
// The dissolved nutrient: a concentration over the dish (energy per µm^2), diffusing by an implicit
// scheme that stays stable at long steps. Same method names as the GDScript class it replaced.
#include "params.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <map>
#include <vector>

namespace godot {

class NutrientField : public RefCounted {
	GDCLASS(NutrientField, RefCounted)

	int n = 48;
	int max_across = 0; // the most cells across this dish's grid (0: the default, G.field_max_across)
	double own_diffusion = 0.0; // how fast the nutrient spreads in this dish's medium, µm^2/s (0: the default, G.diffusion)
	double spacing = 12.5, origin = 300.0, radius = 300.0;
	std::vector<float> conc;
	std::vector<uint8_t> inside;
	std::vector<int> owner; // for each cell, the cell whose nutrient it has: itself if it is inside the dish, else its nearest inside neighbour (-1: none)
	std::vector<float> eff; // a copy of the field with the rim cells' stand-in values filled in, for many readers at once (see snapshot)
	int inside_count = 0;

	// A fresh plankton's nutrient is a small cloud, much smaller than a cell of a big dish's grid, and a grid cell cannot
	// hold what a cloud that small is (its gradient is what a swimmer follows). So until it has spread to about a cell it is
	// kept as it really is, a Gaussian: this much nutrient (energy), centred here, with this variance on each axis (µm^2),
	// spreading as 2 D t. Then it is given to the grid, which carries on. The grid and the clouds add up to the nutrient.
	struct Puff {
		double x, y, mass, var;
		double cut = 1.0; // how far out it is looked for, as a multiple of cloud_cut (less for the clouds of a source: hundreds overlap, and their trimmed tails would add up to a missing far field)
	};
	std::vector<Puff> puffs;
	std::vector<double> hmass; // the clouds' masses as the step began (what a bup's wish was shared out by: see take_from_clouds)
	// A source (a pipette) releases nutrient steadily at a point; on a grid too coarse for the plume near it, what it releases
	// is kept up and let go as a small cloud every so often (at first often, then every EMIT_INTERVAL seconds), each given the
	// spread that what it released over that time has had. Keyed by where the source is.
	struct Emitter {
		double x = 0, y = 0, mass = 0, age = 0, lived = 0;
		uint64_t epoch = 0;
	};
	std::map<uint64_t, Emitter> emitters;
	uint64_t emit_epoch = 0;
	void release_emitter(Emitter &e);
	void add_puff(double x, double y, double mass, double var, double cut = 1.0);
	double hash_age = 0.0; // sim seconds the clouds have spread since the lists were last made (they are made afresh when it passes HASH_REFRESH)
	bool hash_keep = false; // the steps are short enough that the next lists are made to be kept (see HASH_REFRESH)
	mutable double hash_spread = 0.0; // how much the clouds' variance may grow before the lists no longer hold every bin a cloud reaches
	// The puffs filed by place so that a read looks at one short list: the dish is cut into square 'bins' two grid cells
	// across, and each puff is listed in every bin its reach can touch until the lists are made again (see puff_reach_ahead).
	// Rebuilt when the puffs change (and by `snapshot`, so that the many readers of a step find it done). Per puff, what a read
	// needs besides where it is (note_puff: brought up to date every step).
	mutable bool hash_dirty = true;
	mutable int bins_across = 1;
	mutable double bin_size = 1.0;
	mutable std::vector<int> bin_start, bin_entries;
	mutable std::vector<int> scratch_lo_x, scratch_hi_x, scratch_lo_y, scratch_hi_y, scratch_next; // (kept between rebuilds so that one does not allocate)
	mutable std::vector<double> ha, hb, hreach2, hsigma; // a = 1 / (2 pi var), b = 1 / (2 var), reach2: how far (squared) it can be told from the medium
	double puff_reach(const Puff &p) const; // how far (µm) from its centre a cloud is above cloud_cut of the detection floor: past that it is not looked for
	double puff_reach_ahead(const Puff &p, double spread) const;
	double note_puff(size_t k) const;
	void rebuild_hash() const;
	void puff_sum(double x, double y, double &c, double &gx, double &gy) const; // adds the puffs' concentration and gradient at the point
	void puff_probe(double x, double y, double &c, double &gx, double &gy, double &sigma) const; // the same, and the smallest sigma among the clouds that reach it
	void deposit_gaussian(double x, double y, double mass, double var);
	double grid_total() const;
	double grid_concentration_xy(double x, double y) const; // the grid's own concentration at a point (bilinear), without the clouds
	double take_from_grid(double x, double y, double energy); // the cell the point is in gives up to this much
	template <typename F>
	void each_puff(double x, double y, F fn) const; // calls fn(puff index, dx, dy, r2) for each cloud that reaches the point
	std::vector<float> view_values() const; // the grid's concentrations with the puffs' added at the cell centres, for pictures
	double view_cell(const std::vector<float> &view, int ix, int iy) const;

	double patch_amplitude = 0.0, patch_size = 10000.0;
	uint64_t patch_seed = 0;
	double patch_noise(double x, double y) const; // fractal noise at a place in the dish (zero on average; see set_patchiness)
	int index_at(double x, double y) const;
	void build(double dish_radius, int cells_across);
	int nearest_inside(int ix, int iy) const; // (for `build`, which keeps the answers in `owner`)
	double cell_value(int ix, int iy) const { // a cell's concentration, a rim cell's being its owner's
		int o = owner[(size_t)iy * n + ix];
		return o < 0 ? 0.0 : (double)conc[o];
	}
	// The grid's bilinear read, which every read of the field shares: `cell(ix, iy)` gives a cell's value (the field as it is, its
	// snapshot, ...); `c` is the concentration at the point and gx, gy its gradient (a caller that wants only `c` leaves them unused).
	template <typename Cell>
	inline void bilinear(double x, double y, Cell cell, double &c, double &gx, double &gy) const {
		double fx = std::clamp((x + origin) / spacing - 0.5, 0.0, n - 1.001);
		double fy = std::clamp((y + origin) / spacing - 0.5, 0.0, n - 1.001);
		int x0 = (int)fx, y0 = (int)fy;
		double tx = fx - x0, ty = fy - y0;
		double c00 = cell(x0, y0), c10 = cell(x0 + 1, y0), c01 = cell(x0, y0 + 1), c11 = cell(x0 + 1, y0 + 1);
		double top = c00 + (c10 - c00) * tx;
		double bottom = c01 + (c11 - c01) * tx;
		c = top + (bottom - top) * ty;
		gx = ((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty) / spacing;
		gy = (bottom - top) / spacing;
	}
	inline void read_eff(double x, double y, double &c, double &gx, double &gy) const {
		bilinear(x, y, [this](int ix, int iy) { return (double)eff[(size_t)iy * n + ix]; }, c, gx, gy);
	}
	void sweep(bool along_rows, double k);
	void solve_run(int first, int step, int count, double k, double *cp, double *dp);
	void sweep_lines(bool along_rows, double k, int first_line, int last_line);
	void snapshot_rows(int first_row, int last_row);
	// Each cell's share of a feed, patches included. It depends only on the grid and the patch landscape, so it is made once (see `fill`).
	std::vector<double> fill_weights;
	double fill_weight_total = 0.0;
	bool fill_weights_valid = false;
	void ensure_fill_weights();
	// Recording (for the GPU spike): the clouds and deposits that would change this field are kept as events instead, for the GPU,
	// which holds the clouds and the grid. A cloud is x, y, mass, variance, cut; a deposit is a cell and a concentration to add to it.
	bool recording = false;
	std::vector<float> rec_puffs;
	std::vector<int> rec_cells;
	std::vector<float> rec_amounts;
	void add_to_cell(int cell, float amount);
	int threads = 0; // 0: as many as the machine has; 1: just this one (the results are the same)
	// Runs fn(job, block) for each of `blocks` blocks of lines or rows, on the worker threads when the grid is big enough to pay for it.
	void run_blocks(void (*fn)(void *, uint32_t), void *job, int blocks);
	static void run_sweep_block(void *job, uint32_t block);
	static void run_snapshot_block(void *job, uint32_t block);
	struct SweepJob {
		NutrientField *field;
		bool along_rows;
		double k;
	};

protected:
	static void _bind_methods();

public:
	NutrientField() { build(300.0, 48); } // a usable (if small) field even before the first reset
	static int size_for(double dish_radius);
	int size_for_radius(double dish_radius) const; // as size_for, with this field's own most cells across
	void set_max_across(int across) { max_across = across; }
	int get_max_across() const { return max_across > 0 ? max_across : (int)G.field_max_across; }
	void set_diffusion(double d) { own_diffusion = d; }
	void set_threads(int count) { threads = count; }
	double get_diffusion() const { return own_diffusion > 0.0 ? own_diffusion : G.diffusion; }
	void reset(double dish_radius);
	void resize(double dish_radius); // a larger dish: keeps the nutrient (and the total) on a new grid
	int get_size() const { return n; }
	double get_spacing() const { return spacing; }
	bool accepts(const Vector2 &local) const;
	void deposit(const Vector2 &local, double energy);
	void disc_block(double x, double y, double radius, int &x0, int &x1, int &y0, int &y1) const;
	void deposit_disc(const Vector2 &local, double disc_radius, double energy);
	// A plankton's burst: this much nutrient over a disc of this radius at first. Kept as a cloud (see Puff) where the grid is
	// too coarse to hold it, and put straight on the grid where it is not.
	void add_cloud(const Vector2 &local, double disc_radius, double energy);
	void advance_puffs(double dt); // the clouds spread, and the ones that have reached a cell's size go onto the grid
	// A step of the sources: begin_emissions, then emit_xy for each source that is there, then end_emissions (which lets go of
	// what a source that is gone had kept). flush_emitters lets go of what every source has kept (before a save).
	void begin_emissions() { emit_epoch++; }
	void emit_xy(double x, double y, double energy, double dt);
	void end_emissions();
	void flush_emitters();
	int puff_count() const { return (int)puffs.size(); }
	Array puffs_export() const;
	void puffs_import(const Array &saved);
	// The smallest sigma, in µm, among the clouds that reach this point (a huge number if none does): how fine a structure
	// the nutrient has here, for choosing how often a swimmer looks (see BupSim::moves_for_structure).
	double min_cloud_sigma(double x, double y) const;
	double erase_disc(const Vector2 &local, double disc_radius, double strength);
	double sample(const Vector2 &local) const;
	Vector3 read(const Vector2 &local) const;
	Vector2 gradient(const Vector2 &local) const;
	double take(const Vector2 &local, double energy);
	void fill(double concentration); // adds this concentration (energy per µm²) to the dish, on average: patchy if set_patchiness asked for it, though the total is the same
	// A fixed landscape of richer and poorer patches that `fill` follows: fractal noise (patches within patches, each size
	// half the one above and 80% as strong, from `largest_patch_um` down to the grid's own scale) of this relative strength
	// (the standard deviation as a share of the mean), from this seed. It is a function of position, so it is the same after
	// the dish is resized, and it averages to 1, so the total nutrient is what was asked for.
	void set_patchiness(double amplitude, double largest_patch_um, int64_t seed);
	void diffuse(double dt);
	double total() const;
	bool is_empty() const { return total() <= 0.0; }
	PackedFloat32Array values() const;
	void set_recording(bool on) { recording = on; }
	PackedFloat32Array take_recorded_puffs();
	PackedInt32Array take_recorded_cells();
	PackedFloat32Array take_recorded_amounts();
	PackedFloat32Array export_fill_weights(); // what fill(1.0) adds to each cell: for the GPU spike's tests
	PackedInt32Array export_owner() const; // for each cell the cell whose nutrient it has (-1: none): for the GPU spike's tests
	// The grid and the clouds as packed arrays, for moving them to and from the GPU (and for the copy of the GPU's field the dish
	// reads while the GPU runs): {"conc": the n*n concentrations, "puffs": 5 floats a cloud, x, y, mass, variance, cut}.
	// import_packed replaces both (cells outside the dish stay empty, clouds with nothing in them are dropped); the sources'
	// kept-back nutrient is not touched.
	Dictionary export_packed() const;
	void import_packed(const PackedFloat32Array &conc, const PackedFloat32Array &puffs);
	Vector2 cell_centre(int i) const;
	PackedByteArray steer_bytes(double speed, double sense_range, double max_alpha) const; // where a swimmer like this could steer: RGBA, one pixel a cell
	PackedByteArray haze_bytes(double visible_above, double alpha_scale, double max_alpha) const; // the picture of the medium: RGBA, one pixel a cell
	void load_values(const Array &saved);

	// for the simulation core, which works in doubles without going through Vector2
	void read_xy(double x, double y, double &c, double &gx, double &gy) const;
	// `snapshot` copies the concentrations (each rim cell standing in the value of its nearest inside cell, as read_xy
	// takes it) so that `read_snapshot_xy` gives exactly what read_xy would, without the per-cell checks, and safely from
	// many threads at once while nothing changes the field.
	void snapshot(bool readers = true); // `readers` false: nothing will read the field this step (no bups), so nothing is made
	inline void read_snapshot_xy(double x, double y, double &c, double &gx, double &gy) const {
		read_eff(x, y, c, gx, gy);
		if (!puffs.empty()) {
			puff_sum(x, y, c, gx, gy);
		}
	}
	// What read_snapshot_xy gives, and the smallest sigma among the clouds that reach the point (a huge number if none).
	inline void probe_snapshot_xy(double x, double y, double &c, double &gx, double &gy, double &sigma) const {
		read_eff(x, y, c, gx, gy);
		sigma = 1.0e18;
		if (!puffs.empty()) {
			puff_probe(x, y, c, gx, gy, sigma);
		}
	}
	double concentration_xy(double x, double y) const; // just the concentration of read_xy
	// The concentration at a point as the grid's and the clouds' shares, and taking what a bup wants given those (as take_xy,
	// which reads them itself): for the serial uptake pass, which reads each bup's place once.
	struct CloudShare { // which clouds reach a point and how much of the concentration each makes (the first few; `more` if there were others)
		int k[6];
		double c[6];
		double total = 0.0; // the clouds' concentration at the point
		int count = 0;
		bool more = false;
	};
	// The clouds' share of the concentration at a point, as the snapshot has them (safe from many threads at once).
	void cloud_share_xy(double x, double y, CloudShare &share) const;
	double grid_concentration(double x, double y) const { return grid_concentration_xy(x, y); } // the grid's concentration, as it is now
	void concentration_parts_xy(double x, double y, double &from_grid, double &from_clouds, CloudShare &share) const;
	double take_parts_xy(double x, double y, double energy, double from_grid, double from_clouds, const CloudShare &share);
	double take_from_clouds(double x, double y, double energy, double from_clouds, const CloudShare &share); // the clouds' part of a take: this much, out of the clouds that reach the point
	// Uptake by cell, so that the cells can be worked on at the same time. `uptake_cell_xy` is the cell a bup at the point takes from;
	// `uptake_concentration_xy` is what `grid_concentration` gives there, but with every cell other than `own` as it was when the step
	// began (`snapshot`) and `own` as it is now; `take_cell` takes up to this much energy out of a cell.
	int uptake_cell_xy(double x, double y) const { return owner[index_at(x, y)]; }
	double uptake_concentration_xy(double x, double y, int own) const;
	double take_cell(int cell, double energy);
	double cell_concentration(int cell) const { return conc[cell]; }
	void deposit_cell(int cell, double energy) { conc[cell] += (float)(energy / (spacing * spacing)); } // (the second food lives at the cell's resolution: it is let go and taken up in the cell the bup is in)
	double take_xy(double x, double y, double energy);
	void deposit_xy(double x, double y, double energy);
};

} // namespace godot
