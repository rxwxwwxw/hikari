module tests.caddyfile.test_caddyfile;

// Caddyfile parsing, analysis and editing over the fixture corpus in
// tests/fixtures/caddyfiles (expectations.json describes each fixture). The same corpus is
// replayed against a real Caddy binary by tests/integration/caddy/differential.*.

import caddyfile.analyze;
import caddyfile.caddybin;
import caddyfile.detect;
import caddyfile.edit;
import caddyfile.integrate;
import caddyfile.lexer;
import caddyfile.parser;
import std.algorithm : canFind, map, sort, startsWith;
import std.array : array, replace;
import std.conv : to;
import std.exception : assertThrown;
import std.file : copy, dirEntries, exists, mkdirRecurse, read, readText, rmdirRecurse, SpanMode, tempDir, write;
import std.json;
import std.path : buildPath, dirName;

private enum FIXTURES = "tests/fixtures/caddyfiles";

private JSONValue expectations() {
    return parseJSON(readText(buildPath(FIXTURES, "expectations.json")));
}

private string fixtureText(string name) {
    return cast(string) read(buildPath(FIXTURES, name));
}

unittest {
    // Lexer: spans are exact, quoting/comment/heredoc rules match Caddy's.
    auto src = fixtureText("quoting.caddy");
    auto lx = lexCaddyfile(src);
    foreach (t; lx.tokens) {
        assert(t.end > t.start && t.end <= src.length);
        if (!t.quoted) assert(src[t.start .. t.end] == t.text, t.text);
    }
    auto texts = lx.tokens.map!(t => t.text).array;
    assert(texts.canFind(`a "quoted" value with } brace`));
    assert(texts.canFind("#not-a-comment"));          // '#' inside quotes is text
    assert(texts.canFind(`raw "text" {braces}`));      // backtick raw token
    assert(texts.canFind("value#hash"));              // '#' mid-token is text
    assert(lx.comments.length == 2);                   // header comment + "# real comment {"
    assert(lx.comments[0].text.canFind("unbalanced"));

    auto h = lexCaddyfile(fixtureText("heredoc.caddy"));
    auto doc = h.tokens.map!(t => t.heredoc).array.canFind(true);
    assert(doc);
    foreach (t; h.tokens) {
        if (t.heredoc) assert(t.text == "<html>\n  { this is not a block }\n</html>", t.text);
    }
    // The argument after the closing marker belongs to the same directive line.
    auto hp = parseCaddyfile(fixtureText("heredoc.caddy"));
    assert(hp.blocks[0].body[0].name == "respond" && hp.blocks[0].body[0].args.length == 2 && hp.blocks[0].body[0].args[1] == "200");

    auto bom = lexCaddyfile(fixtureText("crlf_bom.caddy"));
    assert(bom.hasBom && bom.crlf);
    assert(bom.tokens[0].text == "example.org");

    assertThrown!CaddyfileSyntaxError(lexCaddyfile("example.com {\n\trespond \"unterminated\n}\n"));
    assertThrown!CaddyfileSyntaxError(lexCaddyfile("example.com {\n\trespond <<EOF\n\tnever closed\n}\n"));
}

unittest {
    // Every fixture: parse result, sites, listeners, globals and verdict match expectations.
    auto ex = expectations();
    auto fqdn = ex["fqdn"].str;
    auto ip = ex["tailscale_ip"].str;
    auto port = cast(ushort) ex["port"].integer;
    foreach (e; ex["fixtures"].array) {
        auto name = e["file"].str;
        auto r = analyzeCaddyfile(buildPath(FIXTURES, name));
        assert(r.parsed == (e["parsed"].type == JSONType.true_), name ~ ": " ~ r.parseError);
        auto v = integrationVerdict(r, fqdn, ip, port);
        auto wantVerdict = e["verdict"].str;
        assert(v.integrable == (wantVerdict == "integrate"), name ~ " verdict: " ~ v.reason);
        assert(v.reason.startsWith(e["reason"].str), name ~ ": reason '" ~ v.reason ~ "' does not start with '" ~ e["reason"].str ~ "'");
        if (!r.parsed) continue;

        if (auto sites = "sites" in e.object) {
            assert(r.sites.length == sites.array.length, name ~ ": site count " ~ to!string(r.sites.length));
            foreach (i, sj; sites.array) {
                assert(r.sites[i].raw == sj["address"].str, name ~ ": " ~ r.sites[i].raw);
                assert(r.sites[i].port == sj["port"].integer, name ~ ": port of " ~ r.sites[i].raw ~ " = " ~ to!string(r.sites[i].port));
                auto wantBinds = sj["binds"].array.map!(b => b.str).array;
                assert(r.sites[i].binds == wantBinds, name ~ ": binds of " ~ r.sites[i].raw);
            }
        }
        if (auto ls = "listeners" in e.object) {
            auto want = ls.array.map!(x => x.str).array;
            sort(want);
            assert(parserListeners(r) == want, name ~ ": listeners " ~ to!string(parserListeners(r)));
        }
        if (auto a = "admin" in e.object) assert(r.globals.admin == a.str, name);
        if (auto a = "auto_https" in e.object) assert(r.globals.autoHttps == a.str, name);
        if (auto a = "crlf" in e.object) assert(r.crlf == (a.type == JSONType.true_), name);
        if (auto a = "bom" in e.object) assert(r.hasBom == (a.type == JSONType.true_), name);
        if (auto a = "hikari_markers" in e.object) assert(r.hikariMarkers == a.integer, name);
        if (auto a = "snippets" in e.object) assert(r.snippetNames == a.array.map!(x => x.str).array, name);
    }
}

unittest {
    // Robustness: CRLF line endings and tab->space indentation do not change what we see.
    auto ex = expectations();
    foreach (e; ex["fixtures"].array) {
        auto name = e["file"].str;
        if (e["parsed"].type != JSONType.true_ || name.canFind("/")) continue;
        auto src = fixtureText(name);
        auto base = analyzeTree(*new CaddyConfigTree(parseCaddyfile(src, "/x/" ~ name)));
        foreach (variant; [src.replace("\r\n", "\n").replace("\n", "\r\n"), src.replace("\t", "    ")]) {
            auto tree = CaddyConfigTree(parseCaddyfile(variant, "/x/" ~ name));
            auto r = analyzeTree(tree);
            assert(r.sites.map!(s => s.raw ~ ":" ~ to!string(s.port)).array == base.sites.map!(s => s.raw ~ ":" ~ to!string(s.port)).array, name);
        }
    }
}

unittest {
    // Parser structure details.
    auto p = parseCaddyfile(fixtureText("many_sites.caddy"));
    assert(p.blocks[0].kind == BlockKind.global);
    assert(p.blocks[1].keys == ["www.example.com", "example.com"]);
    auto m = parseCaddyfile(fixtureText("matchers_proxy.caddy"));
    auto body = m.blocks[0].body;
    assert(body[0].name == "@api" && body[0].hasBlock && body[0].block.length == 2);
    auto rp = body[2];
    assert(rp.name == "reverse_proxy" && rp.args == ["@api", "127.0.0.1:9000", "127.0.0.1:9001"] && rp.block.length == 2);
    auto nr = parseCaddyfile(fixtureText("named_routes.caddy"));
    assert(nr.blocks[0].kind == BlockKind.namedRoute);
    auto bl = parseCaddyfile(fixtureText("braceless.caddy"));
    assert(bl.blocks.length == 1 && !bl.blocks[0].braced && bl.blocks[0].body[0].name == "respond");
    // A brace-less site block is only allowed when it is the only site block.
    assertThrown!CaddyfileSyntaxError(parseCaddyfile("a.com {\n}\nb.com\nrespond hi\n"));
    assertThrown!CaddyfileSyntaxError(parseCaddyfile("example.com {\n\trespond ok\n}\n}\n"));
    assertThrown!CaddyfileSyntaxError(parseCaddyfile("example.com {\n\trespond ok\n"));
}

unittest {
    // Edit engine: append is reversible byte-for-byte and idempotent for every fixture and
    // for the awkward cases (empty, no final newline, CRLF, BOM, trailing blank lines).
    string[] sources = ["", "x", "example.com {\n}", "example.com {\n}\n", "example.com {\n}\n\n\n", "a {\r\n}\r\n", "a {\r\n}", "\xEF\xBB\xBFa {\n}\n"];
    foreach (e; expectations()["fixtures"].array) {
        auto name = e["file"].str;
        auto src = fixtureText(name);
        if (auto orig = "original" in e.object) src = orig.str; // start from the un-integrated form
        sources ~= src;
    }
    foreach (src; sources) {
        auto added = appendImportBlock(src, "hikari.caddy");
        assert(added.startsWith(src), "append must not change existing bytes");
        assert(removeImportBlock(added) == src, "removal must restore the original bytes: [" ~ src ~ "]");
        assert(appendImportBlock(added, "hikari.caddy") == added, "second append must be a no-op");
        auto m = findMarkerRegion(added);
        assert(m.present && m.importTarget == "hikari.caddy");
        auto eol = detectEol(src);
        assert(added[src.length .. $].canFind(eol ~ "import hikari.caddy" ~ eol), "block uses the file's line endings");
        // Content appended later by the operator survives removal.
        auto later = added ~ "late.example.com {\n}\n";
        assert(removeImportBlock(later) == src ~ "late.example.com {\n}\n");
        // Retargeting replaces the block in place.
        auto re = appendImportBlock(added, "other.caddy");
        assert(findMarkerRegion(re).importTarget == "other.caddy" && removeImportBlock(re) == src);
    }

    // Hand-edited or duplicated markers are refused, never "repaired".
    auto good = appendImportBlock("a {\n}\n", "hikari.caddy");
    assertThrown!IntegrationError(findMarkerRegion(good ~ good[6 .. $]));
    assertThrown!IntegrationError(findMarkerRegion(good.replace("import hikari.caddy\n", "import hikari.caddy\nrespond hi\n")));
    assertThrown!IntegrationError(findMarkerRegion(good.replace(END_MARK ~ "\n", "")));
    assertThrown!IntegrationError(removeImportBlock(good.replace("(managed;", "(edited;")));

    assert(dropInFileName("*.caddy") == "hikari.caddy");
    assert(dropInFileName("*") == "hikari");
    assert(dropInFileName("site-*.conf") == "site-hikari.conf");
    assert(dropInFileName("*.*") == "");
    assert(dropInFileName("[ab]*") == "");
}

unittest {
    // Plans: append by default, drop-in when the main file imports a glob, keep the target
    // of an existing block.
    auto ex = expectations();
    foreach (e; ex["fixtures"].array) {
        auto want = "plan" in e.object;
        if (want is null) continue;
        auto path = buildPath(FIXTURES, e["file"].str);
        auto r = analyzeCaddyfile(path);
        auto p = planIntegration(r, readText(path), SITE_FILE_HEADER ~ "\nsite\n");
        assert((p.mode == PlanMode.dropIn ? "drop_in" : "append_import") == want.str, e["file"].str);
        auto wantSite = buildPath(FIXTURES, e["site_file"].str).replace("\\", "/");
        assert(p.siteFilePath.replace("\\", "/").canFind(wantSite.replace("tests/", "")), p.siteFilePath ~ " vs " ~ wantSite);
        if (p.mode == PlanMode.dropIn) assert(!p.mainChanged());
    }
    auto single = analyzeCaddyfile(buildPath(FIXTURES, "single_site.caddy"));
    auto sp = planIntegration(single, fixtureText("single_site.caddy"), "x");
    assert(sp.mode == PlanMode.appendImport && sp.mainChanged() && sp.importTarget == "hikari.caddy");

    assert(isHikariSiteFile(fixtureText("already_integrated/hikari.caddy")));
    assert(!isHikariSiteFile("example.com {\n}\n"));
    // hikari's own imported site never counts as a conflict with itself.
    auto ai = analyzeCaddyfile(buildPath(FIXTURES, "already_integrated/Caddyfile"));
    assert(ai.hikariSiteFiles.length == 1 && ai.sites.length == 1);
}

unittest {
    // Preservation check on synthetic `caddy adapt` output.
    enum before = `{"apps":{"http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"handle":[{"handler":"static_response"}]}]}}},
        "tls":{"automation":{"policies":[{"subjects":["example.com"],"issuers":[{"module":"internal"}]}]}}},"admin":{"disabled":true}}`;
    enum ok = `{"admin":{"disabled":true},"apps":{"tls":{"automation":{"policies":[{"issuers":[{"module":"internal"}],"subjects":["example.com"]},
        {"subjects":["box.tail1234.ts.net"],"get_certificate":[{"via":"tailscale"}]}]}},"http":{"servers":{
        "srv0":{"listen":["100.64.0.10:9100"],"routes":[]},"srv1":{"routes":[{"handle":[{"handler":"static_response"}]}],"listen":[":443"]}}}}}`;
    auto c = checkPreservation(before, ok, "100.64.0.10", 9100, "box.tail1234.ts.net");
    assert(c.ok, to!string(c.problems));               // renamed servers and key order don't matter

    enum changed = `{"admin":{"disabled":true},"apps":{"tls":{"automation":{"policies":[{"subjects":["example.com"],"issuers":[{"module":"internal"}]}]}},
        "http":{"servers":{"srv0":{"listen":[":443"],"routes":[]},"srv1":{"listen":["100.64.0.10:9100"]}}}}}`;
    assert(!checkPreservation(before, changed, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    enum wrongListen = `{"admin":{"disabled":true},"apps":{"tls":{"automation":{"policies":[{"subjects":["example.com"],"issuers":[{"module":"internal"}]}]}},
        "http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"handle":[{"handler":"static_response"}]}]},"srv1":{"listen":[":9100"]}}}}}`;
    assert(!checkPreservation(before, wrongListen, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    enum adminChanged = `{"admin":{"disabled":false},"apps":{"tls":{"automation":{"policies":[{"subjects":["example.com"],"issuers":[{"module":"internal"}]}]}},
        "http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"handle":[{"handler":"static_response"}]}]},"srv1":{"listen":["100.64.0.10:9100"]}}}}}`;
    assert(!checkPreservation(before, adminChanged, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    enum foreignPolicy = `{"admin":{"disabled":true},"apps":{"tls":{"automation":{"policies":[{"subjects":["example.com"],"issuers":[{"module":"internal"}]},
        {"subjects":["evil.example"]}]}},"http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"handle":[{"handler":"static_response"}]}]},"srv1":{"listen":["100.64.0.10:9100"]}}}}}`;
    assert(!checkPreservation(before, foreignPolicy, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    // What real Caddy emits once hikari's policy exists: a bare default-behaviour policy for
    // a site the original already served, plus handle-group renumbering in that server and
    // the candidate file's path in file_server's auto-hide list. All equivalent; accepted.
    enum realBefore = `{"apps":{"http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"match":[{"host":["example.com"]}],
        "handle":[{"handler":"subroute","routes":[{"group":"group0","handle":[{"handler":"file_server","hide":["/etc/caddy/Caddyfile"]}]}]}]}]}}}}}`;
    enum realAfter = `{"apps":{"tls":{"automation":{"policies":[{"subjects":["box.tail1234.ts.net"],"get_certificate":[{"via":"tailscale"}]},{"subjects":["example.com"]}]}},
        "http":{"servers":{"srv0":{"listen":["100.64.0.10:9100"],"routes":[{"group":"group0"}]},"srv1":{"listen":[":443"],"routes":[{"match":[{"host":["example.com"]}],
        "handle":[{"handler":"subroute","routes":[{"group":"group3","handle":[{"handler":"file_server","hide":["/etc/caddy/.Caddyfile.hikari-candidate"]}]}]}]}]}}}}}`;
    string[2][] aliases = [["/etc/caddy/.Caddyfile.hikari-candidate", "/etc/caddy/Caddyfile"]];
    auto realCheck = checkPreservation(realBefore, realAfter, "100.64.0.10", 9100, "box.tail1234.ts.net", aliases);
    assert(realCheck.ok, to!string(realCheck.problems));
    // Without the alias the hide-list difference is (correctly) reported.
    assert(!checkPreservation(realBefore, realAfter, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);
    // A bare policy for a name the original never served is not accepted.
    enum strangerPolicy = `{"apps":{"tls":{"automation":{"policies":[{"subjects":["box.tail1234.ts.net"]},{"subjects":["stranger.example"]}]}},
        "http":{"servers":{"srv0":{"listen":["100.64.0.10:9100"]},"srv1":{"listen":[":443"],"routes":[{"match":[{"host":["example.com"]}],
        "handle":[{"handler":"subroute","routes":[{"group":"group3","handle":[{"handler":"file_server","hide":["/etc/caddy/Caddyfile"]}]}]}]}]}}}}}`;
    assert(!checkPreservation(realBefore, strangerPolicy, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);
    // A host-less original site gets an empty catch-all policy (= defaults): accepted.
    enum hostlessBefore = `{"apps":{"http":{"servers":{"srv0":{"listen":["127.0.0.1:9100"],"routes":[{"handle":[{"body":"ok","handler":"static_response"}]}]}}}}}`;
    enum hostlessAfter = `{"apps":{"tls":{"automation":{"policies":[{"subjects":["box.tail1234.ts.net"],"get_certificate":[{"via":"tailscale"}]},{}]}},
        "http":{"servers":{"a":{"listen":["100.64.0.10:9100"]},"b":{"listen":["127.0.0.1:9100"],"routes":[{"handle":[{"body":"ok","handler":"static_response"}]}]}}}}}`;
    assert(checkPreservation(hostlessBefore, hostlessAfter, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);
    // ...but a catch-all with different settings than the original default is not.
    enum hostlessChanged = `{"apps":{"tls":{"automation":{"policies":[{"subjects":["box.tail1234.ts.net"]},{"issuers":[{"module":"internal"}]}]}},
        "http":{"servers":{"a":{"listen":["100.64.0.10:9100"]},"b":{"listen":["127.0.0.1:9100"],"routes":[{"handle":[{"body":"ok","handler":"static_response"}]}]}}}}}`;
    assert(!checkPreservation(hostlessBefore, hostlessChanged, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    // Re-run: hikari's own earlier server may change; nothing else may.
    enum rerunBefore = `{"apps":{"http":{"servers":{"a":{"listen":[":443"]},"b":{"listen":["100.64.0.10:9100"],"routes":[1]}}}}}`;
    enum rerunAfter = `{"apps":{"http":{"servers":{"x":{"listen":[":443"]},"y":{"listen":["100.64.0.10:9100"],"routes":[2]}}}}}`;
    assert(checkPreservation(rerunBefore, rerunAfter, "100.64.0.10", 9100, "box.tail1234.ts.net").ok);

    assert(adaptedListeners(ok) == ["100.64.0.10:9100", ":443"].dup.sort.array);
    assert(parseCaddyVersion("v2.9.1 h1:abc=") == [2u, 9u, 1u]);
    assert(parseCaddyVersion("v2.10.0-beta.3") == [2u, 10u, 0u]);
    assert(versionAtLeast([2u, 10u, 0u], 2, 6) && !versionAtLeast([2u, 5u, 2u], 2, 6) && !versionAtLeast(null, 2, 6));
}

unittest {
    // Service-definition parsing for detection.
    enum show = "ExecStart={ path=/usr/bin/caddy ; argv[]=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile ; ignore_errors=no ; start_time=[n/a] }\nLoadState=loaded\nActiveState=active\n";
    auto inv = caddyArgsToConfig(parseSystemdExecStart(show));
    assert(inv.isCaddy && inv.subcommand == "run" && inv.config == "/etc/caddy/Caddyfile" && !inv.resume);
    assert(fromInvocation(inv, "caddy.service", "systemd", "active").note == "");

    auto api = caddyArgsToConfig(["/usr/bin/caddy", "run", "--environ", "--resume"]);
    assert(api.resume && fromInvocation(api, "caddy-api.service", "systemd", "").note.canFind("admin API"));
    assert(fromInvocation(caddyArgsToConfig(["caddy", "run", "--config", "/etc/caddy/caddy.json"]), "c", "systemd", "").note.canFind("JSON"));
    assert(fromInvocation(caddyArgsToConfig(["caddy", "run", "--config=/x/conf.yaml", "--adapter=yaml"]), "c", "systemd", "").note.canFind("yaml"));
    assert(fromInvocation(caddyArgsToConfig(["caddy", "run"]), "c", "systemd", "").note.canFind("unknown"));
    assert(!caddyArgsToConfig(["/usr/bin/nginx", "-g", "daemon off;"]).isCaddy);
    assert(caddyArgsToConfig([`C:\Tools\Caddy\caddy.exe`, "run", "--config", `C:\Tools\Caddy\Caddyfile`]).config == `C:\Tools\Caddy\Caddyfile`);

    enum plist = `<?xml version="1.0"?><plist><dict><key>Label</key><string>homebrew.mxcl.caddy</string>
        <key>ProgramArguments</key><array><string>/opt/homebrew/opt/caddy/bin/caddy</string><string>run</string>
        <string>--config</string><string>/opt/homebrew/etc/Caddyfile</string></array></dict></plist>`;
    auto mac = caddyArgsToConfig(parseLaunchdProgramArguments(plist));
    assert(mac.isCaddy && mac.config == "/opt/homebrew/etc/Caddyfile");
}

unittest {
    // unintegrate on real files restores the original bytes and removes only hikari's file.
    auto dir = buildPath(tempDir(), "hikari-test-unintegrate");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) { if (exists(dir)) rmdirRecurse(dir); }
    mkdirRecurse(dir);
    auto original = "\xEF\xBB\xBFexample.com {\r\n\trespond ok\r\n}";
    auto main = buildPath(dir, "Caddyfile");
    write(main, appendImportBlock(original, "hikari.caddy"));
    write(buildPath(dir, "hikari.caddy"), SITE_FILE_HEADER ~ "\nhttps://box:9100 {\n}\n");
    write(buildPath(dir, "keep.caddy"), "unrelated\n");

    IntegrateOptions o;
    o.caddyfile = main;
    o.dryRun = true;
    auto dry = unintegrate(o);
    assert(dry.ok && dry.changed && exists(buildPath(dir, "hikari.caddy")), dry.message);

    o.dryRun = false;
    auto res = unintegrate(o);
    assert(res.ok, res.message);
    assert(cast(string) read(main) == original, "Caddyfile must be byte-identical to the original");
    assert(!exists(buildPath(dir, "hikari.caddy")));
    assert(exists(buildPath(dir, "keep.caddy")));
    assert(res.backup.length > 0 && exists(res.backup));
    assert(unintegrate(o).changed == false); // nothing left to remove

    // A file at the site path that hikari did not write is never deleted.
    write(main, appendImportBlock(original, "hikari.caddy"));
    write(buildPath(dir, "hikari.caddy"), "someone else's file\n");
    unintegrate(o);
    assert(exists(buildPath(dir, "hikari.caddy")));
}

unittest {
    // integrate dry run without a caddy binary: plans and shows the change, writes nothing.
    auto dir = buildPath(tempDir(), "hikari-test-integrate-dry");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) { if (exists(dir)) rmdirRecurse(dir); }
    mkdirRecurse(dir);
    auto main = buildPath(dir, "Caddyfile");
    copy(buildPath(FIXTURES, "single_site.caddy"), main);
    IntegrateOptions o;
    o.caddyfile = main;
    o.fqdn = "box.tail1234.ts.net";
    o.ip = "100.64.0.10";
    o.webDir = "/opt/hikari/versions/current/web";
    o.dryRun = true;
    auto res = integrate(o);
    assert(res.ok && !res.verified && res.mode == "append_import", res.message);
    assert(res.diff.canFind("+import hikari.caddy"));
    assert(readText(main) == fixtureText("single_site.caddy"));
    assert(!exists(buildPath(dir, "hikari.caddy")));

    // A real run without a caddy binary refuses (it cannot verify).
    o.dryRun = false;
    auto realRun = integrate(o);
    assert(!realRun.ok && realRun.message.canFind("caddy binary"));
    assert(readText(main) == fixtureText("single_site.caddy"));

    // Conflicting configs are refused before anything else happens.
    copy(buildPath(FIXTURES, "conflict_9100.caddy"), main);
    o.dryRun = true;
    assert(!integrate(o).ok);
}
