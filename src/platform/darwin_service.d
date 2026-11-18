module platform.darwin_service;
version (OSX):

import core.model;
import core.sys.posix.unistd : geteuid;
import platform.command;
import std.file : exists;
import std.algorithm : canFind;
import tailnet.discovery : parseTailscaleStatusJson, parsePeerInfoPayload;

DoctorCheck[] macosServiceChecks(string httpsInfoUrl = "", string fqdn = "") {
    DoctorCheck[] checks;
    foreach (label; ["io.hikari.agent", "io.hikari.caddy", "io.hikari.recover"]) {
        auto result = runLocalCommand(["/bin/launchctl", "print", "system/" ~ label], 3000, 16384);
        checks ~= DoctorCheck(label, result.status == 0 ? "pass" : "warn",
            result.status == 0 ? "System-domain LaunchDaemon registered" : "System-domain LaunchDaemon unavailable",
            result.status == 0 ? "" : "Run the privileged installer; inspect launchctl print system/" ~ label);
    }
    auto executable = tailscaleExecutable();
    string variant;
    if (executable.canFind("/Applications/Tailscale.app/")) {
        if (exists("/Applications/Tailscale.app/Contents/_MASReceipt/receipt"))
            variant = "App Store Tailscale app (receipt present)";
        else if (exists("/Applications/Tailscale.app/Contents/Library/SystemExtensions"))
            variant = "Standalone Tailscale system-extension app";
        else variant = "Tailscale app (variant unconfirmed)";
    } else variant = "PATH/standalone CLI (verify installed daemon variant)";
    checks ~= DoctorCheck("macos_tailscale_variant", variant.canFind("unconfirmed") || variant.canFind("verify") ? "warn" : "pass", variant ~ ": " ~ executable, "");
    foreach (account; ["_hikari", "_hikari_caddy"]) {
        if (geteuid() != 0) {
            checks ~= DoctorCheck(account ~ "_tailscale", "warn", "Service-account CLI access unverified",
                "Run sudo hikari doctor to validate noninteractive Tailscale access as each service account");
            continue;
        }
        // Already-privileged doctor drops privileges; probes never elevate.
        auto result = runLocalCommand(["/usr/bin/sudo", "-n", "-u", account, "--",
            executable, "status", "--json"], 5000, 4 * 1024 * 1024);
        bool ok = result.status == 0 && !result.outputTruncated
            && parseTailscaleStatusJson(result.output).available;
        checks ~= DoctorCheck(account ~ "_tailscale", ok ? "pass" : "warn",
            ok ? "Noninteractive service-account status access works" : "Service-account status access failed",
            ok ? "" : "Check the installed Tailscale variant and its supported daemon permissions; hikari will not modify Tailscale settings");
    }
    if (httpsInfoUrl.length) {
        auto result = runLocalCommand(["/usr/bin/curl", "--fail", "--silent", "--show-error",
            "--max-time", "5", httpsInfoUrl], 6000, 65536);
        bool ok = result.status == 0 && !result.outputTruncated
            && parsePeerInfoPayload(result.output, fqdn).ok;
        checks ~= DoctorCheck("macos_https_boundary", ok ? "pass" : "warn",
            ok ? "TLS-verified local tailnet info endpoint responds" : "TLS-verified local tailnet info endpoint unavailable",
            ok ? "" : "Inspect hikari-caddy logs and certificate API permission for _hikari_caddy; never disable TLS verification");
    }
    return checks;
}
