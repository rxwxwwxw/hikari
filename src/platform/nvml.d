module platform.nvml;

import core.model;
import std.conv : to;
import std.string : fromStringz;
import std.typecons : Nullable;

version (Posix) {
    import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_LAZY;
} else version (Windows) {
    import core.sys.windows.winbase : FreeLibrary, GetProcAddress, LoadLibraryA;
    import core.sys.windows.windef : HMODULE;
}

private enum int NVML_SUCCESS = 0;
private enum uint NVML_TEMPERATURE_GPU = 0;

private struct NvmlUtilization {
    uint gpu;
    uint memory;
}

private struct NvmlMemory {
    ulong total;
    ulong free;
    ulong used;
}

private struct NvmlPciInfo {
    char[32] busIdLegacy;
    uint domain;
    uint bus;
    uint device;
    uint pciDeviceId;
    uint pciSubSystemId;
    char[32] busId;
}

private extern (C) @nogc nothrow {
    alias fn_nvmlInit_v2 = int function();
    alias fn_nvmlShutdown = int function();
    alias fn_nvmlDeviceGetCount_v2 = int function(uint* deviceCount);
    alias fn_nvmlDeviceGetHandleByIndex_v2 = int function(uint index, void** device);
    alias fn_nvmlDeviceGetName = int function(void* device, char* name, uint length);
    alias fn_nvmlDeviceGetPciInfo_v3 = int function(void* device, NvmlPciInfo* pci);
    alias fn_nvmlDeviceGetUtilizationRates = int function(void* device, NvmlUtilization* utilization);
    alias fn_nvmlDeviceGetMemoryInfo = int function(void* device, NvmlMemory* memory);
    alias fn_nvmlDeviceGetTemperature = int function(void* device, uint sensorType, uint* temp);
    alias fn_nvmlDeviceGetPowerUsage = int function(void* device, uint* powerMw);
}

class NvmlLoader {
    private void* handle = null;
    private bool attempted = false;
    private bool initialized = false;

    private fn_nvmlInit_v2 pInit;
    private fn_nvmlShutdown pShutdown;
    private fn_nvmlDeviceGetCount_v2 pGetCount;
    private fn_nvmlDeviceGetHandleByIndex_v2 pGetHandle;
    private fn_nvmlDeviceGetName pGetName;
    private fn_nvmlDeviceGetPciInfo_v3 pGetPciInfo;
    private fn_nvmlDeviceGetUtilizationRates pGetUtil;
    private fn_nvmlDeviceGetMemoryInfo pGetMem;
    private fn_nvmlDeviceGetTemperature pGetTemp;
    private fn_nvmlDeviceGetPowerUsage pGetPower;

    ~this() {
        unload();
    }

    private void* loadSymbol(const(char)* symName) {
        version (Posix) {
            return dlsym(handle, symName);
        } else version (Windows) {
            return cast(void*) GetProcAddress(cast(HMODULE) handle, symName);
        } else {
            return null;
        }
    }

    private void closeLib() {
        version (Posix) {
            if (handle !is null) dlclose(handle);
        } else version (Windows) {
            if (handle !is null) FreeLibrary(cast(HMODULE) handle);
        }
        handle = null;
    }

    void unload() {
        if (initialized && pShutdown !is null) {
            pShutdown();
            initialized = false;
        }
        closeLib();
    }

    bool ensureLoaded() {
        if (initialized) return true;
        if (attempted && handle is null) return false;
        attempted = true;

        version (Posix) {
            handle = dlopen("libnvidia-ml.so.1".ptr, RTLD_LAZY);
            if (handle is null) {
                handle = dlopen("libnvidia-ml.so".ptr, RTLD_LAZY);
            }
        } else version (Windows) {
            handle = cast(void*) LoadLibraryA("nvml.dll".ptr);
            if (handle is null) {
                handle = cast(void*) LoadLibraryA(`C:\Windows\System32\nvml.dll`.ptr);
            }
        }

        if (handle is null) return false;

        pInit = cast(fn_nvmlInit_v2) loadSymbol("nvmlInit_v2".ptr);
        if (pInit is null) pInit = cast(fn_nvmlInit_v2) loadSymbol("nvmlInit".ptr);
        pShutdown = cast(fn_nvmlShutdown) loadSymbol("nvmlShutdown".ptr);
        pGetCount = cast(fn_nvmlDeviceGetCount_v2) loadSymbol("nvmlDeviceGetCount_v2".ptr);
        if (pGetCount is null) pGetCount = cast(fn_nvmlDeviceGetCount_v2) loadSymbol("nvmlDeviceGetCount".ptr);
        pGetHandle = cast(fn_nvmlDeviceGetHandleByIndex_v2) loadSymbol("nvmlDeviceGetHandleByIndex_v2".ptr);
        if (pGetHandle is null) pGetHandle = cast(fn_nvmlDeviceGetHandleByIndex_v2) loadSymbol("nvmlDeviceGetHandleByIndex".ptr);
        pGetName = cast(fn_nvmlDeviceGetName) loadSymbol("nvmlDeviceGetName".ptr);
        pGetPciInfo = cast(fn_nvmlDeviceGetPciInfo_v3) loadSymbol("nvmlDeviceGetPciInfo_v3".ptr);
        if (pGetPciInfo is null) pGetPciInfo = cast(fn_nvmlDeviceGetPciInfo_v3) loadSymbol("nvmlDeviceGetPciInfo".ptr);
        pGetUtil = cast(fn_nvmlDeviceGetUtilizationRates) loadSymbol("nvmlDeviceGetUtilizationRates".ptr);
        pGetMem = cast(fn_nvmlDeviceGetMemoryInfo) loadSymbol("nvmlDeviceGetMemoryInfo".ptr);
        pGetTemp = cast(fn_nvmlDeviceGetTemperature) loadSymbol("nvmlDeviceGetTemperature".ptr);
        pGetPower = cast(fn_nvmlDeviceGetPowerUsage) loadSymbol("nvmlDeviceGetPowerUsage".ptr);

        if (pInit is null || pGetCount is null || pGetHandle is null) {
            closeLib();
            return false;
        }

        if (pInit() != NVML_SUCCESS) {
            closeLib();
            return false;
        }
        initialized = true;
        return true;
    }

    RawGpuResult sample() {
        RawGpuResult res;
        if (!ensureLoaded()) {
            res.state = CapabilityState.unsupported;
            return res;
        }
        uint count = 0;
        if (pGetCount(&count) != NVML_SUCCESS) {
            res.state = CapabilityState.error;
            res.error = "nvml_device_count_failed";
            return res;
        }
        if (count == 0) {
            res.state = CapabilityState.unsupported;
            return res;
        }

        res.state = CapabilityState.ok;
        foreach (i; 0 .. count) {
            void* dev = null;
            if (pGetHandle(i, &dev) != NVML_SUCCESS || dev is null) continue;

            GpuDynamicStatus g;
            g.id = "nvml:" ~ to!string(i);
            g.vendor = "NVIDIA";
            g.capability = CapabilityState.ok;

            if (pGetName !is null) {
                char[128] buf;
                if (pGetName(dev, buf.ptr, cast(uint) buf.length) == NVML_SUCCESS) {
                    buf[$ - 1] = '\0';
                    g.display_name = fromStringz(buf.ptr).idup;
                }
            }
            if (g.display_name.length == 0) g.display_name = "NVIDIA GPU " ~ to!string(i);

            if (pGetPciInfo !is null) {
                NvmlPciInfo pci;
                if (pGetPciInfo(dev, &pci) == NVML_SUCCESS) {
                    auto bid = fromStringz(pci.busId.ptr).idup;
                    if (bid.length > 0) g.id = "pci:" ~ bid;
                }
            }

            if (pGetUtil !is null) {
                NvmlUtilization util;
                if (pGetUtil(dev, &util) == NVML_SUCCESS) {
                    g.utilization_pct = cast(double) util.gpu;
                }
            }
            if (pGetMem !is null) {
                NvmlMemory mem;
                if (pGetMem(dev, &mem) == NVML_SUCCESS) {
                    g.vram_used_bytes = mem.used;
                    g.vram_total_bytes = mem.total;
                }
            }
            if (pGetTemp !is null) {
                uint temp = 0;
                if (pGetTemp(dev, NVML_TEMPERATURE_GPU, &temp) == NVML_SUCCESS) {
                    g.temp_c = cast(double) temp;
                }
            }
            if (pGetPower !is null) {
                uint mw = 0;
                if (pGetPower(dev, &mw) == NVML_SUCCESS) {
                    g.power_watts = cast(double) mw / 1000.0;
                }
            }

            res.gpus ~= g;
        }

        if (res.gpus.length == 0) res.state = CapabilityState.unsupported;
        return res;
    }
}
