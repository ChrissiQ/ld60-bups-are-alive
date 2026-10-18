#pragma once
// The dissolved nutrient: a concentration over the dish (energy per µm^2), diffusing by an implicit
// scheme that stays stable at long steps. Same method names as the GDScript class it replaced.
#include "params.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class NutrientField : public RefCounted {
	GDCLASS(NutrientField, RefCounted)

	int n = 48;
	double spacing = 12.5, origin = 300.0, radius = 300.0;
	std::vector<float> conc;
	std::vector<uint8_t> inside;
	std::vector<double> cp, dp;
	int inside_count = 0;

	int index_at(double x, double y) const;
	void build(double dish_radius, int cells_across);
	int nearest_inside(int ix, int iy) const;
	double cell_value(int ix, int iy) const;
	void sweep(bool along_rows, double k);
	void solve_run(int first, int step, int count, double k);

protected:
	static void _bind_methods();

public:
	NutrientField() { build(300.0, 48); } // a usable (if small) field even before the first reset
	static int size_for(double dish_radius);
	void reset(double dish_radius);
	void resize(double dish_radius); // a larger dish: keeps the nutrient (and the total) on a new grid
	int get_size() const { return n; }
	double get_spacing() const { return spacing; }
	bool accepts(const Vector2 &local) const;
	void deposit(const Vector2 &local, double energy);
	void deposit_disc(const Vector2 &local, double disc_radius, double energy);
	double erase_disc(const Vector2 &local, double disc_radius, double strength);
	double sample(const Vector2 &local) const;
	Vector3 read(const Vector2 &local) const;
	Vector2 gradient(const Vector2 &local) const;
	double take(const Vector2 &local, double energy);
	void fill(double energy);
	void diffuse(double dt);
	double total() const;
	bool is_empty() const { return total() <= 0.0; }
	PackedFloat32Array values() const;
	Vector2 cell_centre(int i) const;
	PackedByteArray steer_bytes(double speed, double sense_range, double max_alpha) const; // where a swimmer like this could steer: RGBA, one pixel a cell
	PackedByteArray haze_bytes(double visible_above, double alpha_scale, double max_alpha) const; // the picture of the medium: RGBA, one pixel a cell
	void load_values(const Array &saved);

	// for the simulation core, which works in doubles without going through Vector2
	void read_xy(double x, double y, double &c, double &gx, double &gy) const;
	double take_xy(double x, double y, double energy);
	void deposit_xy(double x, double y, double energy);
};

} // namespace godot
