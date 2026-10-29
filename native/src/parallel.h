#pragma once

#include <godot_cpp/classes/worker_thread_pool.hpp>

#include <cstdint>
#include <cstring>
#include <vector>

// Runs fn(job, 0) ... fn(job, count - 1): on the calling thread when `threads` is 1, when there is no more than one piece or when
// `worth_pool` says the work is too small to hand over, otherwise across the worker pool (`threads` of them, or all when it is
// not above 1). Returns when every piece has run.
inline void parallel_for(void (*fn)(void *, uint32_t), void *job, int count, int threads, bool worth_pool, const char *name) {
	godot::WorkerThreadPool *pool = godot::WorkerThreadPool::get_singleton();
	if (threads == 1 || count <= 1 || pool == nullptr || !worth_pool) {
		for (int i = 0; i < count; i++) {
			fn(job, (uint32_t)i);
		}
		return;
	}
	godot::WorkerThreadPool::GroupID group = pool->add_native_group_task(fn, job, count, threads > 1 ? threads : -1, true, name);
	pool->wait_for_group_task_completion(group);
}

// A copy of a vector as a packed array (Godot's PackedFloat32Array, PackedInt32Array...).
template <typename Packed, typename T>
Packed to_packed(const std::vector<T> &v) {
	Packed out;
	out.resize((int64_t)v.size());
	if (!v.empty()) {
		memcpy(out.ptrw(), v.data(), v.size() * sizeof(T));
	}
	return out;
}
