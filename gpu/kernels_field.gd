class_name GpuKernelsField
extends RefCounted
## The field's kernels and the bups' uptake from it (see gpu/kernels.gd for how a kernel is made and registered): the feed, the
## diffusion of the nutrient and of the acetate, the snapshot the bups read, swimming, the bups' demand on the cells and the clouds,
## the cells' shares, and what each bup takes and lets go.

const FIELD_FUNCS := """
// the field's concentration (and its gradient) at a point, bilinear in the snapshot, as the CPU's read_snapshot_xy
void readf(float x, float y, out float c, out float gx, out float gy) {
	int n = int(P[P_CELLS]); float sp = P[P_SPACING];
	float fx = clamp((x + P[P_ORIGIN]) / sp - 0.5, 0.0, float(n) - 1.001);
	float fy = clamp((y + P[P_ORIGIN]) / sp - 0.5, 0.0, float(n) - 1.001);
	int x0 = int(fx), y0 = int(fy);
	float tx = fx - float(x0), ty = fy - float(y0);
	int i0 = y0 * n + x0;
	float c00 = EFF[i0], c10 = EFF[i0 + 1], c01 = EFF[i0 + n], c11 = EFF[i0 + n + 1];
	float top = c00 + (c10 - c00) * tx;
	float bottom = c01 + (c11 - c01) * tx;
	c = top + (bottom - top) * ty;
	gx = ((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty) / sp;
	gy = (bottom - top) / sp;
}
"""

const LOOKUP_FUNCS := """
void lookup(float s, float eps, out float f, out float along, out float across) {
	int ns = int(P[P_MOTION_NS]), ne = int(P[P_MOTION_NE]);
	float below = 1.0;
	if (s < P[P_MOTION_S0]) { below = s / P[P_MOTION_S0]; s = P[P_MOTION_S0]; }
	float x = clamp((log(s) - P[P_MOTION_LS0]) / P[P_MOTION_DLS], 0.0, float(ns - 1) - 1e-4);
	float y = clamp((log(max(eps, 1e-12)) - P[P_MOTION_LE0]) / P[P_MOTION_DLE], 0.0, float(ne - 1) - 1e-4);
	int i = int(x), j = int(y);
	float tx = x - float(i), ty = y - float(j);
	int k00 = i * ne + j, k10 = k00 + ne, k01 = k00 + 1, k11 = k10 + 1;
	float w00 = (1.0 - tx) * (1.0 - ty), w10 = tx * (1.0 - ty), w01 = (1.0 - tx) * ty, w11 = tx * ty;
	int o1 = ns * ne, o2 = 2 * ns * ne, o3 = 3 * ns * ne;
	f = below * (TABLE[k00] * w00 + TABLE[k10] * w10 + TABLE[k01] * w01 + TABLE[k11] * w11);
	along = TABLE[o1 + k00] * w00 + TABLE[o1 + k10] * w10 + TABLE[o1 + k01] * w01 + TABLE[o1 + k11] * w11;
	across = TABLE[o2 + k00] * w00 + TABLE[o2 + k10] * w10 + TABLE[o2 + k01] * w01 + TABLE[o2 + k11] * w11;
	if (below < 1.0) {
		float flatd = TABLE[o3 + j] * (1.0 - ty) + TABLE[o3 + j + 1] * ty;
		along = flatd + (along - flatd) * below;
		across = flatd + (across - flatd) * below;
	}
}
"""

const K_CLEAR := """
void main() { uint i = gl_GlobalInvocationID.x; if (i >= uint(P[P_CELLS] * P[P_CELLS])) return; DLO[i] = 0u; DHI[i] = 0u; RLO[i] = 0u; RHI[i] = 0u; ALO[i] = 0u; AHI[i] = 0u; }
"""

const K_SNAPSHOT := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= uint(P[P_CELLS] * P[P_CELLS])) return;
	int o = OWNER[i];
	EFF[i] = o >= 0 ? CONC[o] : 0.0;
}
"""

const K_SWIM := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	uint b = i * RECORD_WORDS;
	float x = BUPS[b + R_X], y = BUPS[b + R_Y], dx = BUPS[b + R_DX], dy = BUPS[b + R_DY];
	float energy = BUPS[b + R_ENERGY], mass = BUPS[b + R_MASS];
	float speed = BUPS[b + R_SPEED], sense = BUPS[b + R_SENSE], metab = BUPS[b + R_METABOLISM], drag = P[P_DRAG_UPKEEP] * BUPS[b + R_SPEED] * BUPS[b + R_SPEED], donor = BUPS[b + R_DONOR];  // (the drag cost from the speed gene)
	float delta = P[P_DELTA];
	uint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 12345U) + i * 0x9E3779B9U);  // (this dish's stream, this step, this bup)
	float size = sqrt(mass);
	float srange = sense * sqrt(size / P[P_REFERENCE_SIZE]);
	float sense_k = P[P_GRADIENT_NOISE] * (P[P_REFERENCE_SENSE] / srange);
	float radius = P[P_RADIUS];
	float limit = radius - 0.5 * mass * P[P_MASS_UM];
	float nw2 = limit > 0.0 ? limit * limit : -1.0;
	float hx = 0.0, hy = 0.0, hl = 0.0; bool pending = false;
	float floor_c = P[P_DETECTION_FLOOR], noise_ref = P[P_NOISE_REFERENCE];
	// what it reads at the start, and from the clouds that reach it how finely to cut its step (as the CPU's moves_for_structure)
	float c0, gx0, gy0; readf(x, y, c0, gx0, gy0);
	float pc, pgx, pgy, sig; puffs_at(x, y, pc, pgx, pgy, sig);
	c0 += pc; gx0 += pgx; gy0 += pgy;
	int moves = 0;
	bool fine = P[P_MOVES] > 0.5 && delta <= P[P_FINE_STEP];  // (a step as short as the fine step: it follows the individual run and tumble, as the CPU's swim_by_runs)
	if (P[P_MOVES] > 0.5 && !fine) {
		float structure = min(P[P_SPACING], 2.0 * sig);
		float sc = max(1.0, structure / max(P[P_MOTION_STRUCTURE], 1.0));
		moves = max(1, int(ceil(delta / (P[P_MOTION_STEP] * sc * sc))));
	}
	float sub = delta / float(max(moves, 1));
	for (int m = 0; m < moves; m++) {
		float c, gx, gy;
		if (m == 0) { c = c0; gx = gx0; gy = gy0; }
		else {
			readf(x, y, c, gx, gy);
			float qc, qgx, qgy, qs; puffs_at(x, y, qc, qgx, qgy, qs);
			c += qc; gx += qgx; gy += qgy;
		}
		float lx = gx / (floor_c + c), ly = gy / (floor_c + c);
		float glen = sqrt(lx * lx + ly * ly);
		float err = min(sense_k * sqrt(noise_ref / max(c, 1e-5)), 5.0);
		float f, along, across; lookup(speed * glen, err, f, along, across);
		float kick = 2.0 * speed * speed * sub;
		float up = gauss(s) * sqrt(along * kick);
		float side = gauss(s) * sqrt(across * kick);
		float sx = up, sy = side;
		if (glen > 1e-9) {
			float ux = lx / glen, uy = ly / glen;
			up += speed * f * sub;
			sx = ux * up - uy * side;
			sy = uy * up + ux * side;
		}
		x += sx; y += sy;
		float sl = sqrt(sx * sx + sy * sy);
		if (sl > 1e-6) { hx = sx; hy = sy; hl = sl; pending = true; }
		if (x * x + y * y > nw2) {
			float dist = sqrt(x * x + y * y);
			if (dist > limit && limit > 0.0) {
				float back = 2.0 * limit - dist;
				back = back < 0.5 * limit ? limit : back;
				x = x * back / dist; y = y * back / dist;
			}
			if (pending) { dx = hx / hl; dy = hy / hl; pending = false; }
			dist = sqrt(x * x + y * y);
			if (dist > limit) {
				float nx = x / dist, ny = y / dist;
				x = nx * limit; y = ny * limit;
				float dt = dx * nx + dy * ny;
				float ax = dx - nx * dt, ay = dy - ny * dt;
				float al = sqrt(ax * ax + ay * ay);
				if (al < 0.1) { float sg = u01(s) < 0.5 ? 1.0 : -1.0; ax = -ny * sg; ay = nx * sg; al = 1.0; }
				dx = ax / al; dy = ay / al;
			}
		}
	}
	if (pending) { dx = hx / hl; dy = hy / hl; }
	if (fine) {
		// It reads the nutrient where it is (on a log scale) and compares it with its own recent past, and tumbles less often while it improves; while
		// it tumbles it does not swim; a run bends a little by rotational diffusion.
		float memory = exp(-delta / P[P_MEMORY_SHORT]);
		float noise = BUPS[b + R_NOISE] * memory + sqrt(1.0 - memory * memory) * gauss(s);
		float signal = log(1.0 + c0 / floor_c);
		float fast = BUPS[b + R_FAST], slow = BUPS[b + R_SLOW];
		if (fast < 0.0) { fast = signal; slow = signal; }  // (none read yet)
		fast += (signal - fast) * (1.0 - memory);
		slow += (signal - slow) * (1.0 - exp(-delta / P[P_MEMORY_LONG]));
		float err_now = min(sense_k * sqrt(noise_ref / max(c0, 1e-5)), 5.0);
		float rate = P[P_TUMBLE_BASE] * clamp(1.0 - P[P_CHEMOTAXIS_GAIN] * (fast - slow + err_now * noise), P[P_TUMBLE_UP_FACTOR], 1.0);
		float tumbling = BUPS[b + R_TUMBLING];
		if (tumbling > 0.0) {
			tumbling -= delta;
		} else {
			float turn;
			if (u01(s) < rate * delta) {
				tumbling = P[P_TUMBLE_SECONDS];
				turn = gauss(s) * P[P_TUMBLE_TURN_SPREAD] + P[P_TUMBLE_TURN_MEAN];
				if (u01(s) >= 0.5) turn = -turn;
			} else {
				turn = gauss(s) * P[P_ROTATIONAL_DIFFUSION] * sqrt(delta);
			}
			float cs = cos(turn), sn = sin(turn);
			float ndx = dx * cs - dy * sn, ndy = dx * sn + dy * cs;
			float nl = sqrt(ndx * ndx + ndy * ndy);
			if (nl > 0.0) { dx = ndx / nl; dy = ndy / nl; } else { dx = ndx; dy = ndy; }
			x += dx * speed * delta; y += dy * speed * delta;
		}
		float dist = sqrt(x * x + y * y);
		if (dist > limit) {  // (the wall: it is turned along it, and slides until a tumble frees it)
			float nx = x / dist, ny = y / dist;
			x = nx * limit; y = ny * limit;
			float dt = dx * nx + dy * ny;
			float ax = dx - nx * dt, ay = dy - ny * dt;
			float al = sqrt(ax * ax + ay * ay);
			if (al < 0.1) { float sg = u01(s) < 0.5 ? 1.0 : -1.0; ax = -ny * sg; ay = nx * sg; al = 1.0; }
			dx = ax / al; dy = ay / al;
		}
		BUPS[b + R_FAST] = fast; BUPS[b + R_SLOW] = slow; BUPS[b + R_NOISE] = noise; BUPS[b + R_TUMBLING] = tumbling;
	} else {
		BUPS[b + R_FAST] = -1.0;  // (the signal memory isn't kept up while drifting)
	}
	BUPS[b + R_X] = x; BUPS[b + R_Y] = y; BUPS[b + R_DX] = dx; BUPS[b + R_DY] = dy;
	// then it pays its upkeep and grows (with the stationary phase on, a bup at the growth floor pays only the starving maintenance, from the
	// reserve and then from its body)
	if (P[P_STATIONARY] > 0.5 && energy <= P[P_MAINTENANCE_FLOOR]) {
		energy -= P[P_STARVE_COST] * mass * delta;
		if (energy < 0.0) { mass += energy / P[P_COST_PER_MASS]; energy = 0.0; }
		BUPS[b + R_ENERGY] = energy; BUPS[b + R_MASS] = mass;
		return;
	}
	float upkeep = P[P_UPKEEP_SCALE] * (P[P_BASE_UPKEEP] + P[P_MAINTENANCE_PER_MASS] * mass) + drag * size + P[P_SENSE_UPKEEP] * sense;
	energy -= upkeep * delta;
	if (energy > P[P_MAINTENANCE_FLOOR]) {
		int rl = int(BUPS[b + R_REACH] + 0.5);
		float raised = float((rl & 3) + ((rl >> 2) & 3) + ((rl >> 4) & 3) + ((rl >> 6) & 3));
		float grow = min(P[P_GROWTH_RATE] * metab * mass * delta * (donor > 0.5 ? 1.0 - P[P_DONOR_COST] : 1.0) * max(0.2, 1.0 - P[P_REACH_COST] * raised) * (((rl >> 8) & 3) == 2 ? 1.0 - P[P_KEY_COST] : 1.0), (energy - P[P_MAINTENANCE_FLOOR]) / P[P_COST_PER_MASS]);  // (a donor, and a bup with raised ceilings, give up a share of their growth)
		energy -= grow * P[P_COST_PER_MASS];
		mass += grow;
	}
	BUPS[b + R_ENERGY] = energy; BUPS[b + R_MASS] = mass;
}
"""

const K_DEMAND := """
// the grid's concentration a bup at the point reads (bilinear in the snapshot), and how much of it is its own cell's (`own`)
void readc(float x, float y, int own, out float c, out float own_share) {
	int n = int(P[P_CELLS]); float sp = P[P_SPACING];
	float fx = clamp((x + P[P_ORIGIN]) / sp - 0.5, 0.0, float(n) - 1.001);
	float fy = clamp((y + P[P_ORIGIN]) / sp - 0.5, 0.0, float(n) - 1.001);
	int x0 = int(fx), y0 = int(fy);
	float tx = fx - float(x0), ty = fy - float(y0);
	int i0 = y0 * n + x0;
	float c00 = EFF[i0], c10 = EFF[i0 + 1], c01 = EFF[i0 + n], c11 = EFF[i0 + n + 1];
	float top = c00 + (c10 - c00) * tx;
	float bottom = c01 + (c11 - c01) * tx;
	c = top + (bottom - top) * ty;
	own_share = 0.0;
	if (OWNER[i0] == own) own_share += (1.0 - tx) * (1.0 - ty);
	if (OWNER[i0 + 1] == own) own_share += tx * (1.0 - ty);
	if (OWNER[i0 + n] == own) own_share += (1.0 - tx) * ty;
	if (OWNER[i0 + n + 1] == own) own_share += tx * ty;
}
void add_fixed(uint cell, float w, int which) { // what is wanted (0), what is read (1) and the own cell's share of it (2), summed per cell
	if (which == 0) ADD_FIXED30(DLO, DHI, cell, w)
	else if (which == 1) ADD_FIXED30(RLO, RHI, cell, w)
	else ADD_FIXED30(ALO, AHI, cell, w)
}
void add_puff_demand(uint k, float mass) { ADD_FIXED20(PDLO, PDHI, k, mass) }
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	uint b = i * RECORD_WORDS;
	float x = BUPS[b + R_X], y = BUPS[b + R_Y], energy = BUPS[b + R_ENERGY], mass = BUPS[b + R_MASS], metab = BUPS[b + R_METABOLISM], yld = exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]);  // (the yield, from harm and metabolism)
	float max_e = P[P_RESERVE_PER_MASS] * mass;
	WANT[i] = -1.0; WANTC[i] = 0.0; CELLOF[i] = -1;
	if (energy < max_e) {
		int n = int(P[P_CELLS]);
		int ix = clamp(int((x + P[P_ORIGIN]) / P[P_SPACING]), 0, n - 1), iy = clamp(int((y + P[P_ORIGIN]) / P[P_SPACING]), 0, n - 1);
		int o = OWNER[iy * n + ix];
		float cg = 0.0, own_share = 0.0;
		if (o >= 0) readc(x, y, o, cg, own_share);
		float cc, pgx, pgy, psig; puffs_at(x, y, cc, pgx, pgy, psig);
		float ct = cg + cc;
		if (ct > 0.0) {
			float rate = P[P_UPTAKE_PER_SIZE] * sqrt(mass) * metab;
			float room = max(max_e - energy, 0.0) / yld;
			float w = min(rate * ct / (P[P_HALF_SATURATION] + ct) * P[P_DELTA], room);
			if (w > 0.0) {
				float wg = cc > 0.0 ? w * cg / ct : w;
				float wc = w - wg;
				if (o >= 0 && CONC[o] > 0.0 && wg > 0.0) {
					WANT[i] = wg; CELLOF[i] = o;
					add_fixed(uint(o), wg, 0);
					add_fixed(uint(o), wg * min(cg / CONC[o], 8.0), 1);
					add_fixed(uint(o), wg * own_share, 2);
				}
				if (wc > 0.0 && cc > 0.0) {
					WANTC[i] = wc;
					int nb = int(P[P_BINS_ACROSS]); float bs = P[P_BIN_SIZE];
					int bx = clamp(int((x + P[P_ORIGIN]) / bs), 0, nb - 1), by = clamp(int((y + P[P_ORIGIN]) / bs), 0, nb - 1);
					uint bin = uint(by * nb + bx);
					uint e0 = BINS[bin], e1 = min(e0 + BINC[bin], uint(P[P_ENTRY_CAPACITY]));
					for (uint e = e0; e < e1; e++) {
						vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];
						float ddx = x - r0.x, ddy = y - r0.y, r2 = fma(ddy, ddy, ddx * ddx);
						if (r2 <= r1.x) {
							uint k = uint(r1.z);
							float ci = r0.z / (6.2831853 * r0.w) * exp(-r2 * 0.5 / r0.w);
							add_puff_demand(k, wc * ci / cc);
						}
					}
				}
			}
		}
	}
}
"""

const K_CELLS := """
float neglog1m(float x) { // -ln(1 - x)
	if (x < 0.01) return x * (1.0 + x * (0.5 + x * (0.33333333 + x * 0.25)));
	return -log(1.0 - x);
}
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= uint(P[P_CELLS] * P[P_CELLS])) return;
	if (OWNER[i] != int(i)) return;
	float d = float(DHI[i]) * 4.0 + float(DLO[i]) * 9.313225746154785e-10; // what the bups there wanted
	SCALE[i] = 0.0;
	float c0 = CONC[i];
	if (d <= 0.0 || c0 <= 0.0) return;
	float rho = (float(RHI[i]) * 4.0 + float(RLO[i]) * 9.313225746154785e-10) / d; // the concentration they read, as a share of this cell's
	float al = max((float(AHI[i]) * 4.0 + float(ALO[i]) * 9.313225746154785e-10) / d, 0.02); // and how much of what they read is this cell's
	float ct = max(rho * c0, 1e-12);
	float area = P[P_SPACING] * P[P_SPACING];
	float k = P[P_HALF_SATURATION];
	// What they take as they run the cell down while their uptake follows what they read, ct - al u (u: what has been taken, as a
	// concentration): u + (k / al) (-ln(1 - al u / ct)) = d (k + ct) / (area ct), found by bisection.
	float y = d * (k + ct) / (area * ct);
	float lo = 0.0, hi = min(min(d / area, c0 * 0.999999), ct * 0.999999 / al);
	if (hi + (k / al) * neglog1m(al * hi / ct) <= y) {
		lo = hi;
	} else {
		for (int it = 0; it < 32; it++) {
			float mid = 0.5 * (lo + hi);
			if (mid + (k / al) * neglog1m(al * mid / ct) < y) lo = mid; else hi = mid;
		}
		lo = 0.5 * (lo + hi);
	}
	SCALE[i] = lo * area / d;
	CONC[i] = c0 - lo;
}
"""

const K_APPLY := """
// A bup that takes in more than its growth can use lets go of acetate besides (the CPU's `acetate_share`; its own gain is the same), and a bup with room then takes up acetate (`take_acetate`).
void add_fixed2(uint cell, float w, int which) { // the acetate wanted (0) and let go (1), summed per cell
	if (which == 0) ADD_FIXED30(AWLO, AWHI, cell, w)
	else ADD_FIXED30(ADLO, ADHI, cell, w)
}
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	uint b = i * RECORD_WORDS;
	float wg = WANT[i], wc = WANTC[i];
	float mass = BUPS[b + R_MASS], yld = exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]);
	float max_e = P[P_RESERVE_PER_MASS] * mass;
	float energy = BUPS[b + R_ENERGY];
	float x = BUPS[b + R_X], y = BUPS[b + R_Y];
	int n = int(P[P_CELLS]);
	int ix = clamp(int((x + P[P_ORIGIN]) / P[P_SPACING]), 0, n - 1), iy = clamp(int((y + P[P_ORIGIN]) / P[P_SPACING]), 0, n - 1);
	int o = OWNER[iy * n + ix];
	WANT2[i] = 0.0;
	if (wg > 0.0 || wc > 0.0) {
		float got = wg > 0.0 ? wg * SCALE[CELLOF[i]] : 0.0;
		if (wc > 0.0) {
			float cc, pgx, pgy, psig; puffs_at(x, y, cc, pgx, pgy, psig);
			int nb = int(P[P_BINS_ACROSS]); float bs = P[P_BIN_SIZE];
			int bx = clamp(int((x + P[P_ORIGIN]) / bs), 0, nb - 1), by = clamp(int((y + P[P_ORIGIN]) / bs), 0, nb - 1);
			uint bin = uint(by * nb + bx);
			uint e0 = BINS[bin], e1 = min(e0 + BINC[bin], uint(P[P_ENTRY_CAPACITY]));
			for (uint e = e0; e < e1; e++) {
				vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];
				float ddx = x - r0.x, ddy = y - r0.y, r2 = fma(ddy, ddy, ddx * ddx);
				if (r2 <= r1.x) {
					uint k = uint(r1.z);
					float ci = r0.z / (6.2831853 * r0.w) * exp(-r2 * 0.5 / r0.w);
					got += wc * ci / cc * PSCALE[k];
				}
			}
		}
		float let_go = 0.0;
		if (got > 0.0 && mass > 0.0 && o >= 0) {
			float per_hour = got * yld / (P[P_COST_PER_MASS] * mass * P[P_DELTA]) * 3600.0;
			let_go = got * min(0.5, P[P_ACETATE_SLOPE] * max(0.0, per_hour - P[P_ACETATE_THRESHOLD]));
			if (let_go > 0.0) add_fixed2(uint(o), let_go, 1);
		}
		energy = min(energy + got * yld, max_e);
	}
	// the acetate in the cell, wanted after the glucose: with room left, at its share of the glucose rate, less while there is glucose
	float room = max_e - energy;
	if (o >= 0 && room > 0.0 && CONC2[o] > 0.0) {
		float ca = CONC2[o], cg = max(CONC[o], 0.0);
		float rate = P[P_ACETATE_UPTAKE] * (((int(BUPS[b + R_REACH] + 0.5) >> 8) & 3) == 2 ? P[P_KEY_FACTOR] : 1.0) * P[P_UPTAKE_PER_SIZE] * sqrt(mass) * BUPS[b + R_METABOLISM];
		float w2 = min(rate * ca / (P[P_HALF_SATURATION] + ca) * (P[P_HALF_SATURATION] / (P[P_HALF_SATURATION] + cg)) * P[P_DELTA], room / yld);
		if (w2 > 0.0) {
			WANT2[i] = w2; CELL2[i] = o;
			add_fixed2(uint(o), w2, 0);
		}
	}
	BUPS[b + R_ENERGY] = energy;
}
"""

## The acetate's cells: what the bups there wanted is taken from the cell, all of it if it holds that much, else a share each (`SCALE2`);
## then what they let go is added (it can be eaten from the next step).
const K_AC_CELLS := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= uint(P[P_CELLS] * P[P_CELLS])) return;
	float d = float(AWHI[i]) * 4.0 + float(AWLO[i]) * 9.313225746154785e-10;
	float dep = float(ADHI[i]) * 4.0 + float(ADLO[i]) * 9.313225746154785e-10;
	float area = P[P_SPACING] * P[P_SPACING];
	float c = CONC2[i];
	float s = 0.0;
	if (d > 0.0 && c > 0.0) {
		s = min(1.0, c * area / d);
		c = max(c - d * s / area, 0.0);
	}
	SCALE2[i] = s;
	CONC2[i] = c + dep / area;
	AWLO[i] = 0u; AWHI[i] = 0u; ADLO[i] = 0u; ADHI[i] = 0u;
}
"""

const K_AC_APPLY := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	float w = WANT2[i];
	if (w <= 0.0) return;
	uint b = i * RECORD_WORDS;
	BUPS[b + R_ENERGY] = min(BUPS[b + R_ENERGY] + w * SCALE2[CELL2[i]] * exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]), P[P_RESERVE_PER_MASS] * BUPS[b + R_MASS]);
}
"""

## Diffusion by explicit sub-steps (each moves a cell's share k of the difference with every inside neighbour; stable for k <= 0.25, here at most 0.2):
## the same operator as the CPU's (no flux through the rim), exact in what it conserves, and a thousand times cheaper on a GPU than the CPU's
## line solves, which are one long chain of dependent steps per line. SRC and DST are the two copies of the field, swapped each time.
const K_DIFFUSE := """
void main() {
	uint i = gl_GlobalInvocationID.x;
	int n = int(P[P_CELLS]);
	if (i >= uint(n * n)) return;
	if (INSIDE[i] == 0) { DST[i] = SRC[i]; return; }
	int x = int(i) % n, y = int(i) / n;
	float c = SRC[i], acc = 0.0, k = pcs.pb;
	if (x > 0 && INSIDE[i - 1u] != 0) acc += SRC[i - 1u] - c;
	if (x < n - 1 && INSIDE[i + 1u] != 0) acc += SRC[i + 1u] - c;
	if (y > 0 && INSIDE[i - uint(n)] != 0) acc += SRC[i - uint(n)] - c;
	if (y < n - 1 && INSIDE[i + uint(n)] != 0) acc += SRC[i + uint(n)] - c;
	DST[i] = c + k * acc;
}
"""

const K_FEED := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= uint(P[P_CELLS] * P[P_CELLS])) return;
	CONC[i] += P[P_FEED] * WGT[i];
}
"""


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	GpuKernels.add(out, "feed", K_FEED, ["P", "CONC", "WGT"])
	GpuKernels.add(out, "clear", K_CLEAR, ["P", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI"])
	GpuKernels.add(out, "snapshot", K_SNAPSHOT, ["P", "CONC", "OWNER", "EFF"])
	GpuKernels.add(out, "swim", K_SWIM, ["P", "CNT", "BUPS", "EFF", "TABLE", "ENTD", "BINS", "BINC"], FIELD_FUNCS + LOOKUP_FUNCS + GpuKernelsClouds.CLOUD_FUNCS)
	GpuKernels.add(out, "demand", K_DEMAND, ["P", "CNT", "BUPS", "EFF", "OWNER", "CONC", "WANT", "WANTC", "CELLOF", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "ENTD", "BINS", "BINC", "PDLO", "PDHI"], GpuKernels.FIXED_FUNCS + GpuKernelsClouds.CLOUD_FUNCS)
	GpuKernels.add(out, "cells", K_CELLS, ["P", "CONC", "OWNER", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "SCALE"])
	GpuKernels.add(out, "apply", K_APPLY, ["P", "CNT", "BUPS", "WANT", "WANTC", "CELLOF", "SCALE", "ENTD", "BINS", "BINC", "PSCALE", "OWNER", "CONC", "CONC2", "WANT2", "CELL2", "AWLO", "AWHI", "ADLO", "ADHI"], GpuKernels.FIXED_FUNCS + GpuKernelsClouds.CLOUD_FUNCS)
	GpuKernels.add(out, "ac_cells", K_AC_CELLS, ["P", "CONC2", "AWLO", "AWHI", "ADLO", "ADHI", "SCALE2"])
	GpuKernels.add(out, "ac_apply", K_AC_APPLY, ["P", "CNT", "BUPS", "WANT2", "CELL2", "SCALE2"])
	GpuKernels.add(out, "diffuse2_a", K_DIFFUSE.replace("SRC", "CONC2").replace("DST", "CONC2B"), ["P", "INSIDE", "CONC2", "CONC2B"])
	GpuKernels.add(out, "diffuse2_b", K_DIFFUSE.replace("SRC", "CONC2B").replace("DST", "CONC2"), ["P", "INSIDE", "CONC2B", "CONC2"])
	GpuKernels.add(out, "diffuse_a", K_DIFFUSE.replace("SRC", "CONC").replace("DST", "EFF"), ["P", "INSIDE", "CONC", "EFF"])
	GpuKernels.add(out, "diffuse_b", K_DIFFUSE.replace("SRC", "EFF").replace("DST", "CONC"), ["P", "INSIDE", "EFF", "CONC"])
