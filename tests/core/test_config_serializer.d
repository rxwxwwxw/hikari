module tests.core.test_config_serializer;

import core.config;
import core.model;
import core.serializer;
import platform.command : parseCaddyVersionOutput, parseTailscaleVersionOutput;
import std.algorithm : canFind;
import std.exception : assertThrown;
import std.json : JSONType, parseJSON;

unittest {
    // Reject non-loopback bind addresses
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"0.0.0.0"}}`));
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"::"}}`));
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"192.168.1.50"}}`));

    // Preserve unknown operator keys and enforce updates trust check
    auto cfg = parseConfigJson(`{
        "schema_version": 1,
        "listen": {"tailnet_port": 9443, "loopback_port": 19105, "base_path": "/hikari/"},
        "operator_notes": "keep me across upgrades",
        "updates": {"repo": "OWNER/REPO", "mode": "on_dashboard_open"}
    }`);
    assert(cfg.listen.tailnet_port == 9443);
    assert(cfg.listen.base_path == "/hikari");
    assert(!cfg.updates.isTrustConfigured(), "Placeholder OWNER/REPO must not pass trust verification");

    auto savedJson = configToJson(cfg);
    assert("operator_notes" in savedJson.object);
    assert(savedJson["operator_notes"].str == "keep me across upgrades");
}

unittest {
    // Sanitize OS strings & verify nullable JSON contract rules
    assert(sanitizeOsString("  Evil\x1b[31m\nProcess\tName\x07  ") == "Evil[31m Process Name");

    StatusResponse resp;
    resp.node_id = "hikari:1111";
    resp.host = "test-host\n";
    resp.os = "linux";
    resp.arch = "x86_64";
    resp.server_ts = 1794945600;
    resp.drift.hikari_version = AGENT_VERSION;
    resp.drift.caddy_version = "2.11.9";
    resp.drift.tailscale_version = "1.78.1";
    // cpu.pct, load_1m, temp_c left uninitialized (null)
    // gpus, batteries left empty arrays []

    auto j = serializeStatusResponse(resp);
    assert(j["schema_version"].integer == 1);
    assert(j["cpu"]["pct"].type == JSONType.null_, "Unknown CPU rate must serialize as JSON null, never 0");
    assert(j["cpu"]["temp_c"].type == JSONType.null_);
    assert(j["gpus"].type == JSONType.array && j["gpus"].array.length == 0);
    assert(j["batteries"].type == JSONType.array && j["batteries"].array.length == 0);
    assert(j["host"].str == "test-host");
    assert(j["drift"]["hikari_version"].str == AGENT_VERSION);
    assert(j["drift"]["caddy_version"].str == "2.11.9");
    assert(j["drift"]["tailscale_version"].str == "1.78.1");

    InfoResponse ir;
    ir.node_id = "hikari:1111";
    ir.host = "test-host";
    ir.os = "linux";
    ir.arch = "x86_64";
    ir.caddy_version = "2.11.9";
    auto ij = serializeInfoResponse(ir);
    assert(ij["hikari_version"].str == AGENT_VERSION);
    assert(ij["caddy_version"].str == "2.11.9");
    assert(ij["tailscale_version"].type == JSONType.null_);

    // Version output parsers
    assert(parseCaddyVersionOutput("v2.11.9 h1:abcdef123456\n") == "2.11.9");
    assert(parseCaddyVersionOutput("2.10.0\n") == "2.10.0");
    assert(parseCaddyVersionOutput("(devel)\n") == "");
    assert(parseCaddyVersionOutput("") == "");

    assert(parseTailscaleVersionOutput("1.76.6-t5f3e2a1b4-g123\n  tailscale commit: abc\n") == "1.76.6");
    assert(parseTailscaleVersionOutput("1.78.1\n  go version: go1.23\n") == "1.78.1");
    assert(parseTailscaleVersionOutput("1.78.1-ERR-BuildInfo\n") == "1.78.1");
    assert(parseTailscaleVersionOutput("tailscale version v1.80.0\n") == "1.80.0");
    assert(parseTailscaleVersionOutput("unknown") == "");
}
