module tests.platform.test_winservice;

// Pure SCM helpers: command-line quoting, ownership guard, failure policy. These run on
// every CI platform; the live SCM behaviour is covered by tests/integration/windows/test-service.ps1.

import platform.winservice;
import std.exception : assertThrown;

unittest {
    // quoteWindowsArg follows CommandLineToArgvW rules.
    assert(quoteWindowsArg("serve") == "serve");
    assert(quoteWindowsArg("") == `""`);
    assert(quoteWindowsArg(`C:\Program Files\x`) == `"C:\Program Files\x"`);
    assert(quoteWindowsArg(`C:\dir with space\`) == `"C:\dir with space\\"`); // trailing backslash doubled
    assert(quoteWindowsArg(`say "hi"`) == `"say \"hi\""`);
    assert(quoteWindowsArg(`a\"b`) == `"a\\\"b"`);

    // Round-trip through the parser for awkward inputs.
    string[] tricky = [
        "serve", "--service", "--config", `C:\Program Files\hikari\config.json`,
        `C:\trailing\`, `C:\trailing space\`, `quote"inside`, `back\\slashes`, "", "tab\there",
    ];
    auto cmd = buildServiceCommandLine(`C:\Program Files\hikari\hikari.exe`, tricky);
    auto argv = parseWindowsCommandLine(cmd);
    assert(argv.length == tricky.length + 1);
    assert(argv[0] == `C:\Program Files\hikari\hikari.exe`);
    foreach (i, a; tricky) assert(argv[i + 1] == a, a);

    // The executable is always quoted (unquoted service paths are a privilege-escalation bug).
    assert(buildServiceCommandLine(`C:\ProgramData\hikari\hikari.exe`, ["serve"]) == `"C:\ProgramData\hikari\hikari.exe" serve`);
}

unittest {
    enum cfg = `C:\ProgramData\hikari\config\config.json`;
    enum caddyfile = `C:\ProgramData\hikari\config\Caddyfile`;
    auto agent = buildServiceCommandLine(`C:\ProgramData\hikari\versions\current\hikari.exe`, ["serve", "--service", "--config", cfg]);
    auto caddy = buildServiceCommandLine(`C:\ProgramData\hikari\bin\caddy.exe`, ["run", "--config", caddyfile, "--adapter", "caddyfile"]);

    assert(isHikariOwnedImagePath(agent, HikariServiceKind.agent, cfg));
    // Case/slash-insensitive config comparison.
    assert(isHikariOwnedImagePath(agent, HikariServiceKind.agent, `c:/programdata/HIKARI/config/config.json`));
    assert(isHikariOwnedImagePath(caddy, HikariServiceKind.caddy, caddyfile));

    // Foreign or look-alike services are never owned.
    assert(!isHikariOwnedImagePath(`C:\WINDOWS\System32\spoolsv.exe`, HikariServiceKind.agent, cfg));
    assert(!isHikariOwnedImagePath(agent, HikariServiceKind.agent, `C:\ProgramData\hikari-evil\config\config.json`));
    assert(!isHikariOwnedImagePath(agent, HikariServiceKind.caddy, caddyfile));
    assert(!isHikariOwnedImagePath(caddy, HikariServiceKind.agent, cfg));
    auto noService = buildServiceCommandLine(`C:\ProgramData\hikari\versions\current\hikari.exe`, ["serve", "--config", cfg]);
    assert(!isHikariOwnedImagePath(noService, HikariServiceKind.agent, cfg));
    auto otherExe = buildServiceCommandLine(`C:\tools\evil.exe`, ["serve", "--service", "--config", cfg]);
    assert(!isHikariOwnedImagePath(otherExe, HikariServiceKind.agent, cfg));
    // An unrelated Caddy service using its own Caddyfile is not ours.
    auto userCaddy = buildServiceCommandLine(`C:\caddy\caddy.exe`, ["run", "--config", `C:\caddy\Caddyfile`, "--adapter", "caddyfile"]);
    assert(!isHikariOwnedImagePath(userCaddy, HikariServiceKind.caddy, caddyfile));
    // Old WinSW wrapper path is not "native" (installer migrates it separately).
    assert(!isHikariOwnedImagePath(`"C:\ProgramData\hikari\bin\hikari-service.exe"`, HikariServiceKind.agent, cfg));
    assert(!isHikariOwnedImagePath(agent, HikariServiceKind.agent, ""));
}

unittest {
    auto p = defaultFailurePolicy();
    assert(p.resetPeriodSec == 3600);
    assert(p.restartDelaysMs == [5_000u, 30_000u, 120_000u]);

    assert(serviceAccountName("hikari", "virtual") == `NT SERVICE\hikari`);
    assert(serviceAccountName("hikari", "LocalSystem") == "LocalSystem");
    assertThrown!Exception(serviceAccountName("hikari", "administrator"));
}
