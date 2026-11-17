module tests.platform.test_cross_platform;

import core.cache;
import core.config;
import core.coordinator;
import core.model;
import core.serializer;
import hardware.inventory;
import platform.api;
import platform.darwin : parsePmsetBatteryOutput;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.json : JSONType;
import std.math : abs;

unittest {
    // 1. SMBIOS full multi-table parser (Type 0 BIOS, Type 1 System, Type 2 Board, Type 3 Chassis, Type 17 DIMM)
    ubyte[] smbios;
    // Type 0 (BIOS Info, len=0x12)
    smbios ~= [0, 0x12, 0, 0, 1, 2, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    smbios ~= cast(const(ubyte)[]) ("American Megatrends Inc.\0" ~ "F12\0" ~ "03/15/2024\0\0");
    // Type 1 (System Info, len=0x1B)
    smbios ~= [1, 0x1B, 1, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3];
    smbios ~= cast(const(ubyte)[]) ("ASUS\0" ~ "ROG Strix X670E\0" ~ "Gaming Desktop\0\0");
    // Type 2 (Baseboard Info, len=0x08)
    smbios ~= [2, 0x08, 2, 0, 1, 2, 3, 0];
    smbios ~= cast(const(ubyte)[]) ("ASUSTeK COMPUTER INC.\0" ~ "ROG STRIX X670E-E\0" ~ "Rev 1.xx\0\0");
    // Type 3 (Chassis, len=0x06 -> desktop type 3)
    smbios ~= [3, 0x06, 3, 0, 0, 3, 0, 0];
    // Type 17 (Memory Device 16 GiB DDR5-6000)
    smbios ~= [
        17, 0x20, 0x11, 0x00,
        0, 0, 0, 0, 0x40, 0, 0x40, 0,
        0x00, 0x40, // 16384 MiB (16 GiB)
        0x09, 0x00,
        1, 0, 0x22, 0, 0,
        0x70, 0x17, // 6000 MT/s (0x1770)
        2, 0, 0, 3, 0, 0, 0, 0, 0,
    ];
    smbios ~= cast(const(ubyte)[]) ("DIMM_B2\0" ~ "G.Skill\0" ~ "F5-6000J30\0\0");

    auto parsed = parseSmbiosTables(smbios);
    assert(parsed.firmware.type == "UEFI");
    assert(parsed.firmware.vendor == "American Megatrends Inc.");
    assert(parsed.firmware.version_str == "F12");
    assert(parsed.system.manufacturer == "ASUS");
    assert(parsed.system.model == "ROG Strix X670E");
    assert(parsed.system.form_factor == "desktop");
    assert(parsed.board.model == "ROG STRIX X670E-E");
    assert(parsed.memoryModules.length == 1);
    assert(parsed.memoryModules[0].speed_mt_s.get == 6000);
    assert(parsed.memoryModules[0].technology == "DDR5");

    // 2. macOS pmset -g batt parser
    auto bats = parsePmsetBatteryOutput(
        "Now drawing from 'Battery Power'\n" ~
        " -InternalBattery-0 (id=1234567)\t84%; discharging; 4:12 remaining present: true\n"
    );
    assert(bats.length == 1);
    assert(abs(bats[0].pct.get - 84.0) < 0.01);
    assert(bats[0].status == "discharging");
    assert(bats[0].time_remaining_s.get == 4 * 3600 + 12 * 60);
}

unittest {
    // 3. Mixed 3-OS Fleet JSON contract verification (Linux + Windows + macOS Apple Silicon)
    auto tmpDir = tempDir() ~ "/hikari-test-cross-os";
    if (exists(tmpDir)) rmdirRecurse(tmpDir);
    mkdirRecurse(tmpDir);
    scope (exit) { if (exists(tmpDir)) rmdirRecurse(tmpDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = tmpDir;

    // Windows gaming PC: commit present, swap MUST be null, load_1m MUST be null
    auto winFake = new FakePlatformBackend("windows-gaming");
    auto winStore = new TelemetryCacheStore(cfg, "hikari:win-1");
    auto winCoord = new RefreshCoordinator(winFake, winStore);
    auto winSt = winCoord.getStatus();
    assert(winSt.httpStatus == 200);
    auto winJson = serializeStatusResponse(winSt.payload);
    assert(winJson["os"].str == "windows");
    assert(winJson["swap"].type == JSONType.null_, "Windows commit must never masquerade as Unix swap");
    assert("commit" in winJson.object && winJson["commit"]["limit_bytes"].uinteger == 42949672960UL);
    assert(winJson["cpu"]["load_1m"].type == JSONType.null_, "Windows must not invent Unix load_1m");

    // macOS Apple Silicon: P/E core counts & Mac model identifier
    auto macFake = new FakePlatformBackend("macos-arm64");
    auto macStore = new TelemetryCacheStore(cfg, "hikari:mac-1");
    auto macCoord = new RefreshCoordinator(macFake, macStore);
    auto macHw = macCoord.getHardware();
    assert(macHw.httpStatus == 200);
    auto macJson = serializeHardwareInventory(macHw.payload);
    assert(macJson["cpu"]["display_name"].str == "Apple M3");
    assert(macJson["cpu"]["performance_cores"].uinteger == 4);
    assert(macJson["cpu"]["efficiency_cores"].uinteger == 4);
    assert(macJson["board"]["model"].str == "Mac15,3");
    assert(macJson["cpu"]["isa"]["usable"].array.length > 0);
}
