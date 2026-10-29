#pragma once

#include <godot_cpp/variant/string.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>

// What the files of BupSim (bup_sim.cpp and its parts: bup_lineage.cpp, bup_gpu_io.cpp, bup_husks.cpp, bup_conjugation.cpp) share beyond the class.

inline const char *const GENE_NAMES[4] = { "speed", "sense", "metabolism", "size" };

inline int gene_index(const godot::String &name) {
	for (int i = 0; i < 4; i++) {
		if (name == GENE_NAMES[i]) {
			return i;
		}
	}
	return -1;
}

inline double fposmod1(double v) {
	return v - std::floor(v);
}

// The words of the GPU's records and events (little-endian 32-bit words, as the GPU writes them).
inline constexpr float NO_PICTURE = 3e38f; // px, py of a record with no last picture (any value from 1e30 up means the same)
inline constexpr int BIRTH_WORDS = 16, DEATH_WORDS = 14;
inline void put_u32(uint8_t *record, int word, uint32_t v) { memcpy(record + word * 4, &v, 4); }
inline void put_f32(uint8_t *record, int word, float v) { memcpy(record + word * 4, &v, 4); }
inline uint32_t get_u32(const uint8_t *record, int word) {
	uint32_t v;
	memcpy(&v, record + word * 4, 4);
	return v;
}
inline float get_f32(const uint8_t *record, int word) {
	float v;
	memcpy(&v, record + word * 4, 4);
	return v;
}
inline int64_t get_id(const uint8_t *record, int lo_word, int hi_word) {
	return (int64_t)((uint64_t)get_u32(record, lo_word) | ((uint64_t)get_u32(record, hi_word) << 32));
}

// The husks: a dead bup's nutrient leaks out in HUSK_PIECES clouds over its lifetimes; past MAX_HUSKS a death gives its nutrient back at once
// (as the clouds past MAX_CLOUDS go to the grid).
inline constexpr int HUSK_PIECES = 12;
inline constexpr size_t MAX_HUSKS = 200000;
