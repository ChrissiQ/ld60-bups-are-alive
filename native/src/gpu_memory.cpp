#include "gpu_memory.h"

#include <cstdint>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <d3d12.h>
#include <dxgi1_4.h>
#elif defined(__linux__)
#include <dlfcn.h>

#include <vector>
#endif

using namespace godot;

void GpuMemory::_bind_methods() {
	ClassDB::bind_static_method("GpuMemory", D_METHOD("query", "driver", "logical", "physical", "instance", "adapter_name"), &GpuMemory::query);
}

namespace {

Dictionary unknown() {
	Dictionary d;
	d["known"] = false;
	return d;
}

Dictionary known(int64_t dedicated, int64_t budget, int64_t usage, const char *api) {
	Dictionary d;
	d["known"] = true;
	d["dedicated"] = dedicated;
	d["budget"] = budget;
	d["usage"] = usage;
	d["api"] = String(api);
	return d;
}

#if defined(_WIN32)

// Releases a COM interface when it goes out of scope.
template <class T>
struct Com {
	T *p = nullptr;
	Com() = default;
	Com(const Com &) = delete;
	Com &operator=(const Com &) = delete;
	~Com() {
		if (p) {
			p->Release();
		}
	}
	T **out() { return &p; }
};

// The figures of one adapter: IDXGIAdapter1::GetDesc1 (https://learn.microsoft.com/windows/win32/api/dxgi/ns-dxgi-dxgi_adapter_desc1) for the
// dedicated video memory, IDXGIAdapter3::QueryVideoMemoryInfo (dxgi1_4.h) for the local segment group's budget and the process's usage. A
// software adapter has no memory of its own: not known.
bool describe(IDXGIAdapter *p_adapter, Dictionary &r_out) {
	Com<IDXGIAdapter1> a1;
	if (FAILED(p_adapter->QueryInterface(__uuidof(IDXGIAdapter1), (void **)a1.out())) || !a1.p) {
		return false;
	}
	DXGI_ADAPTER_DESC1 desc = {};
	if (FAILED(a1.p->GetDesc1(&desc)) || (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
		return false;
	}
	int64_t budget = 0, usage = 0;
	Com<IDXGIAdapter3> a3;
	if (SUCCEEDED(p_adapter->QueryInterface(__uuidof(IDXGIAdapter3), (void **)a3.out())) && a3.p) {
		DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
		if (SUCCEEDED(a3.p->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
			budget = (int64_t)info.Budget;
			usage = (int64_t)info.CurrentUsage;
		}
	}
	r_out = known((int64_t)desc.DedicatedVideoMemory, budget, usage, "dxgi");
	return true;
}

// The adapter's description as a String.
String description_of(IDXGIAdapter *p_adapter) {
	Com<IDXGIAdapter1> a1;
	DXGI_ADAPTER_DESC1 desc = {};
	if (FAILED(p_adapter->QueryInterface(__uuidof(IDXGIAdapter1), (void **)a1.out())) || !a1.p || FAILED(a1.p->GetDesc1(&desc))) {
		return String();
	}
	return String::utf16((const char16_t *)desc.Description);
}

Dictionary query_windows(const String &p_driver, int64_t p_logical, int64_t p_physical, const String &p_adapter_name) {
	Dictionary out;
	// Direct3D 12: the engine's physical-device handle is its IDXGIAdapter.
	if (p_driver == "d3d12" && p_physical != 0) {
		if (describe(reinterpret_cast<IDXGIAdapter *>(p_physical), out)) {
			return out;
		}
	}
	Com<IDXGIFactory1> factory;
	if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void **)factory.out())) || !factory.p) {
		return unknown();
	}
	// Direct3D 12 without the adapter: the device's LUID (ID3D12Device::GetAdapterLuid) names it (IDXGIFactory4::EnumAdapterByLuid).
	if (p_driver == "d3d12" && p_logical != 0) {
		LUID luid = reinterpret_cast<ID3D12Device *>(p_logical)->GetAdapterLuid();
		Com<IDXGIFactory4> f4;
		Com<IDXGIAdapter> by_luid;
		if (SUCCEEDED(factory.p->QueryInterface(__uuidof(IDXGIFactory4), (void **)f4.out())) && f4.p &&
				SUCCEEDED(f4.p->EnumAdapterByLuid(luid, __uuidof(IDXGIAdapter), (void **)by_luid.out())) && by_luid.p) {
			if (describe(by_luid.p, out)) {
				return out;
			}
		}
	}
	// Otherwise the adapter the engine names, else the one with the most dedicated memory that is not a software adapter.
	Dictionary best;
	int64_t best_dedicated = -1;
	for (UINT i = 0;; i++) {
		Com<IDXGIAdapter1> a;
		if (FAILED(factory.p->EnumAdapters1(i, a.out())) || !a.p) {
			break;
		}
		Dictionary d;
		if (!describe(a.p, d)) {
			continue;
		}
		String name = description_of(a.p);
		if (!p_adapter_name.is_empty() && (name == p_adapter_name || name.contains(p_adapter_name) || p_adapter_name.contains(name))) {
			return d;
		}
		if ((int64_t)d["dedicated"] > best_dedicated) {
			best_dedicated = (int64_t)d["dedicated"];
			best = d;
		}
	}
	return best_dedicated >= 0 ? best : unknown();
}

#elif defined(__linux__)

// The few Vulkan declarations used, as the specification gives them (the Vulkan registry's vulkan_core.h): the library is loaded at run time
// and the handles are the engine's own, so the headers are not needed.
typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef uint64_t VkDeviceSize;
typedef uint32_t VkFlags;
typedef int32_t VkResult;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);

constexpr uint32_t VK_MAX_MEMORY_TYPES = 32;
constexpr uint32_t VK_MAX_MEMORY_HEAPS = 16;
constexpr uint32_t VK_MAX_EXTENSION_NAME_SIZE = 256;
constexpr int32_t VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2 = 1000059006;
constexpr int32_t VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT = 1000237000;
constexpr VkFlags VK_MEMORY_HEAP_DEVICE_LOCAL_BIT = 0x00000001;

struct VkMemoryType {
	VkFlags propertyFlags;
	uint32_t heapIndex;
};
struct VkMemoryHeap {
	VkDeviceSize size;
	VkFlags flags;
};
struct VkPhysicalDeviceMemoryProperties {
	uint32_t memoryTypeCount;
	VkMemoryType memoryTypes[VK_MAX_MEMORY_TYPES];
	uint32_t memoryHeapCount;
	VkMemoryHeap memoryHeaps[VK_MAX_MEMORY_HEAPS];
};
struct VkPhysicalDeviceMemoryProperties2 {
	int32_t sType;
	void *pNext;
	VkPhysicalDeviceMemoryProperties memoryProperties;
};
struct VkPhysicalDeviceMemoryBudgetPropertiesEXT {
	int32_t sType;
	void *pNext;
	VkDeviceSize heapBudget[VK_MAX_MEMORY_HEAPS];
	VkDeviceSize heapUsage[VK_MAX_MEMORY_HEAPS];
};
struct VkExtensionProperties {
	char extensionName[VK_MAX_EXTENSION_NAME_SIZE];
	uint32_t specVersion;
};

typedef void (*PFN_vkGetPhysicalDeviceMemoryProperties)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties *);
typedef void (*PFN_vkGetPhysicalDeviceMemoryProperties2)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties2 *);
typedef VkResult (*PFN_vkEnumerateDeviceExtensionProperties)(VkPhysicalDevice, const char *, uint32_t *, VkExtensionProperties *);

bool has_memory_budget(PFN_vkEnumerateDeviceExtensionProperties p_enumerate, VkPhysicalDevice p_device) {
	uint32_t count = 0;
	if (p_enumerate(p_device, nullptr, &count, nullptr) < 0 || count == 0) {
		return false;
	}
	std::vector<VkExtensionProperties> props(count);
	if (p_enumerate(p_device, nullptr, &count, props.data()) < 0) {
		return false;
	}
	for (uint32_t i = 0; i < count && i < props.size(); i++) {
		props[i].extensionName[VK_MAX_EXTENSION_NAME_SIZE - 1] = 0;
		if (String(props[i].extensionName) == "VK_EXT_memory_budget") {
			return true;
		}
	}
	return false;
}

// The device-local heaps' sizes (vkGetPhysicalDeviceMemoryProperties: VkMemoryHeap with VK_MEMORY_HEAP_DEVICE_LOCAL_BIT), and their budget and
// usage from VkPhysicalDeviceMemoryBudgetPropertiesEXT when the device has VK_EXT_memory_budget (vkGetPhysicalDeviceMemoryProperties2 with
// the structure chained).
Dictionary query_vulkan(int64_t p_physical, int64_t p_instance) {
	if (p_physical == 0 || p_instance == 0) {
		return unknown();
	}
	void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		return unknown();
	}
	Dictionary out = unknown();
	PFN_vkGetInstanceProcAddr get_proc = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
	VkInstance instance = reinterpret_cast<VkInstance>(p_instance);
	VkPhysicalDevice device = reinterpret_cast<VkPhysicalDevice>(p_physical);
	if (get_proc) {
		auto enumerate = (PFN_vkEnumerateDeviceExtensionProperties)get_proc(instance, "vkEnumerateDeviceExtensionProperties");
		auto props2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)get_proc(instance, "vkGetPhysicalDeviceMemoryProperties2");
		if (!props2) {
			props2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)get_proc(instance, "vkGetPhysicalDeviceMemoryProperties2KHR");
		}
		auto props1 = (PFN_vkGetPhysicalDeviceMemoryProperties)get_proc(instance, "vkGetPhysicalDeviceMemoryProperties");
		VkPhysicalDeviceMemoryProperties mem = {};
		bool budgeted = false;
		VkPhysicalDeviceMemoryBudgetPropertiesEXT budget = {};
		bool have = false;
		if (props2 && enumerate && has_memory_budget(enumerate, device)) {
			VkPhysicalDeviceMemoryProperties2 p2 = {};
			p2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2;
			budget.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT;
			p2.pNext = &budget;
			props2(device, &p2);
			mem = p2.memoryProperties;
			budgeted = true;
			have = true;
		} else if (props1) {
			props1(device, &mem);
			have = true;
		}
		if (have && mem.memoryHeapCount <= VK_MAX_MEMORY_HEAPS) {
			int64_t dedicated = 0, total_budget = 0, total_usage = 0;
			for (uint32_t i = 0; i < mem.memoryHeapCount; i++) {
				if (mem.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) {
					dedicated += (int64_t)mem.memoryHeaps[i].size;
					if (budgeted) {
						total_budget += (int64_t)budget.heapBudget[i];
						total_usage += (int64_t)budget.heapUsage[i];
					}
				}
			}
			if (dedicated > 0) {
				out = known(dedicated, total_budget, total_usage, "vulkan");
			}
		}
	}
	dlclose(lib);
	return out;
}

#endif

} // namespace

Dictionary GpuMemory::query(const String &p_driver, int64_t p_logical, int64_t p_physical, int64_t p_instance, const String &p_adapter_name) {
#if defined(_WIN32)
	// Windows reads the memory through DXGI whichever API draws (Direct3D 12 names the adapter itself; Vulkan, OpenGL and the rest by name).
	return query_windows(p_driver, p_logical, p_physical, p_adapter_name);
#elif defined(__linux__)
	if (p_driver == "vulkan") {
		return query_vulkan(p_physical, p_instance);
	}
	return unknown();
#else
	return unknown();
#endif
}
