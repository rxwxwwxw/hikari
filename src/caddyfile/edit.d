module caddyfile.edit;

// The only edits hikari ever makes to someone else's Caddyfile, and how to undo them.
//
//  * Append mode: a marked three-line block at the very end of the main Caddyfile that
//    imports hikari's own site file. Nothing before it is touched; removal restores the
//    original bytes exactly (including a missing final newline, CRLF and BOM).
//  * Drop-in mode: when the main file already imports a glob such as `conf.d/*.caddy`,
//    hikari writes its site file where that glob matches and does not edit the main file.
//
// The pure functions here are exhaustively tested over the fixture corpus; the IO helpers
// write atomically and keep backups.

import caddyfile.analyze;
import std.algorithm : canFind, count, endsWith, sort, startsWith;
import std.conv : to;
import std.string : indexOf, lastIndexOf, strip;

enum string BEGIN_MARK = "# BEGIN hikari (managed; remove with `hikari caddy unintegrate`)";
enum string NOEOL_SUFFIX = " [original had no final newline]";
enum string END_MARK = "# END hikari";
enum string SITE_FILE_HEADER = "# Managed by hikari: regenerated on install/repair. Do not edit; remove with `hikari caddy unintegrate`.";

class IntegrationError : Exception {
    this(string msg) pure @safe { super(msg); }
}

string detectEol(string src) pure @safe {
    auto nl = src.indexOf('\n');
    if (nl > 0 && src[nl - 1] == '\r') return "\r\n";
    return "\n";
}

private struct Line {
    size_t start;   // offset of first char
    size_t end;     // offset of the line terminator (or EOF)
    size_t next;    // offset after the terminator
    string text;    // without terminator
}

private Line[] splitLines(string src) pure @safe {
    Line[] ls;
    size_t s = 0;
    while (s < src.length) {
        auto nl = src[s .. $].indexOf('\n');
        size_t e = nl < 0 ? src.length : s + nl;
        size_t textEnd = (e > s && src[e - 1] == '\r') ? e - 1 : e;
        ls ~= Line(s, textEnd, nl < 0 ? src.length : e + 1, src[s .. textEnd]);
        s = nl < 0 ? src.length : e + 1;
    }
    return ls;
}

struct MarkerRegion {
    bool present;
    bool noEol;
    size_t beginLine;
    string importTarget;
    size_t removeStart;     // byte range that removal deletes
    size_t removeEnd;
}

/// Locates hikari's marked block. Returns `present=false` when there is none and throws
/// IntegrationError when markers exist but are duplicated or were edited by hand
/// (removing them then could delete someone else's content).
MarkerRegion findMarkerRegion(string src) pure @safe {
    MarkerRegion m;
    auto lines = splitLines(src);
    size_t[] begins, ends;
    foreach (i, l; lines) {
        auto t = l.text.strip();
        if (t.startsWith("# BEGIN hikari")) begins ~= i;
        else if (t == END_MARK) ends ~= i;
    }
    if (begins.length == 0 && ends.length == 0) return m;
    if (begins.length != 1 || ends.length != 1) {
        throw new IntegrationError("hikari markers appear " ~ to!string(begins.length) ~ "/" ~ to!string(ends.length)
            ~ " times; fix the Caddyfile by hand (expected exactly one BEGIN and one END)");
    }
    auto b = begins[0], e = ends[0];
    auto beginText = lines[b].text;
    if (e != b + 2 || (beginText != BEGIN_MARK && beginText != BEGIN_MARK ~ NOEOL_SUFFIX)) {
        throw new IntegrationError("the hikari block was edited by hand (expected exactly: BEGIN line, one import line, END line)");
    }
    auto imp = lines[b + 1].text;
    if (!imp.startsWith("import ") || imp.strip().length <= 7) {
        throw new IntegrationError("the hikari block no longer contains a single import line");
    }
    m.present = true;
    m.noEol = beginText.endsWith(NOEOL_SUFFIX);
    m.beginLine = b;
    m.importTarget = imp[7 .. $].strip();

    // Removal range: the block lines plus the separator hikari inserted before them.
    size_t start = lines[b].start;
    auto eol = detectEol(src);
    size_t sepCount = m.noEol ? 2 : (start > 0 ? 1 : 0);
    foreach (_; 0 .. sepCount) {
        if (start >= eol.length && src[start - eol.length .. start] == eol) start -= eol.length;
        else if (start >= 1 && src[start - 1] == '\n') start -= 1;
    }
    m.removeStart = start;
    m.removeEnd = lines[e].next;
    return m;
}

/// Appends the import block. Idempotent: an existing well-formed block is left as is.
string appendImportBlock(string src, string importTarget) pure @safe {
    auto existing = findMarkerRegion(src);
    if (existing.present) {
        if (existing.importTarget == importTarget) return src;
        // Same block pointing elsewhere: replace in place, preserving everything else.
        auto base = removeImportBlock(src);
        return appendImportBlock(base, importTarget);
    }
    auto eol = detectEol(src);
    bool endsWithEol = src.length > 0 && src[$ - 1] == '\n';
    string sep;
    string begin = BEGIN_MARK;
    if (src.length == 0) {
        sep = "";
    } else if (endsWithEol) {
        sep = eol;
    } else {
        sep = eol ~ eol;
        begin = BEGIN_MARK ~ NOEOL_SUFFIX;
    }
    return src ~ sep ~ begin ~ eol ~ "import " ~ importTarget ~ eol ~ END_MARK ~ eol;
}

/// Removes the block, restoring the bytes that existed before `appendImportBlock`.
string removeImportBlock(string src) pure @safe {
    auto m = findMarkerRegion(src);
    if (!m.present) return src;
    return src[0 .. m.removeStart] ~ src[m.removeEnd .. $];
}

/// File name hikari would use for a glob like `*.caddy` (-> `hikari.caddy`) or
/// `site-*` (-> `site-hikari`). Empty when the pattern is not a simple single-`*` glob.
string dropInFileName(string globBaseName) pure @safe {
    if (globBaseName.count('*') != 1 || globBaseName.canFind('?') || globBaseName.canFind('[')) return "";
    auto star = globBaseName.indexOf('*');
    return globBaseName[0 .. star] ~ "hikari" ~ globBaseName[star + 1 .. $];
}

enum PlanMode { appendImport, dropIn }

struct IntegrationPlan {
    PlanMode mode;
    string mainPath;
    string mainOriginal;
    string mainNew;          // == mainOriginal in drop-in mode
    string siteFilePath;
    string siteFileText;
    string importTarget;     // what the import line references (append mode)
    bool mainChanged() const pure nothrow @safe { return mainNew != mainOriginal; }
}

/// Decides how to integrate. `siteText` is the rendered hikari site block.
IntegrationPlan planIntegration(const CaddyfileReport r, string mainSrc, string siteText) @safe {
    import std.path : baseName, buildNormalizedPath, dirName, isAbsolute;
    IntegrationPlan p;
    p.mainPath = r.path;
    p.mainOriginal = mainSrc;
    auto dir = dirName(r.path);

    // Already integrated in append mode: keep the same target.
    auto existing = findMarkerRegion(mainSrc);
    if (!existing.present) {
        foreach (imp; r.imports) {
            if (!imp.topLevel || !imp.isGlob || imp.isSnippet || imp.file != r.path) continue;
            auto full = isAbsolute(imp.pattern) ? imp.pattern : buildNormalizedPath(dir, imp.pattern);
            auto name = dropInFileName(baseName(full));
            auto gdir = dirName(full);
            if (name.length == 0 || gdir.canFind('*') || gdir.canFind('?')) continue;
            p.mode = PlanMode.dropIn;
            p.siteFilePath = buildNormalizedPath(gdir, name);
            p.siteFileText = siteText;
            p.mainNew = mainSrc;
            return p;
        }
    }
    p.mode = PlanMode.appendImport;
    p.importTarget = existing.present ? existing.importTarget : "hikari.caddy";
    p.siteFilePath = isAbsolute(p.importTarget) ? p.importTarget : buildNormalizedPath(dir, p.importTarget);
    p.siteFileText = siteText;
    p.mainNew = appendImportBlock(mainSrc, p.importTarget);
    return p;
}

/// A site file may only be overwritten if hikari wrote it.
bool isHikariSiteFile(string text) pure @safe {
    auto t = text;
    if (t.startsWith("\xEF\xBB\xBF")) t = t[3 .. $];
    return t.startsWith(SITE_FILE_HEADER);
}

/// Minimal unified-style diff for an append-only change (what a dry run prints).
string describeAppend(string before, string after, string path) pure @safe {
    if (before == after) return "(no change to " ~ path ~ ")\n";
    string s = "--- " ~ path ~ "\n+++ " ~ path ~ " (hikari)\n";
    size_t common = 0;
    while (common < before.length && common < after.length && before[common] == after[common]) common++;
    auto ctxStart = before[0 .. common].lastIndexOf('\n');
    // a few lines of context
    size_t lines = 0;
    while (ctxStart > 0 && lines < 3) {
        auto prev = before[0 .. ctxStart].lastIndexOf('\n');
        if (prev < 0) { ctxStart = -1; break; }
        ctxStart = prev;
        lines++;
    }
    size_t from = ctxStart < 0 ? 0 : cast(size_t) ctxStart + 1;
    foreach (l; splitLines(before[from .. common])) s ~= " " ~ l.text ~ "\n";
    auto added = after[common .. $];
    // When the original's last line had no terminator, the first added byte(s) only end
    // that context line; don't show them as an extra blank "+" line.
    if (common > 0 && before[common - 1] != '\n') {
        if (added.startsWith("\r\n")) added = added[2 .. $];
        else if (added.startsWith("\n")) added = added[1 .. $];
    }
    foreach (l; splitLines(added)) s ~= "+" ~ l.text ~ "\n";
    return s;
}

// ---------------------------------------------------------------------------
// IO helpers
// ---------------------------------------------------------------------------

/// Resolves symlinks so edits land on the real file (POSIX). Windows symlinks are refused
/// by the caller rather than followed.
string resolveRealPath(string path) @trusted {
    version (Posix) {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;
        auto p = realpath(path.toStringz(), null);
        if (p is null) return path;
        scope (exit) free(p);
        return fromStringz(p).idup;
    } else {
        return path;
    }
}

/// Copies `path` to `<path>.hikari-backup-<unix time>` and keeps only the newest `keep`.
string backupFile(string path, uint keep = 3) @trusted {
    import std.datetime.systime : Clock;
    import std.file : copy, dirEntries, remove, SpanMode;
    import std.path : baseName, dirName;
    auto ts = Clock.currTime().toUnixTime();
    auto dest = path ~ ".hikari-backup-" ~ to!string(ts);
    copy(path, dest);
    string[] backups;
    foreach (e; dirEntries(dirName(path), baseName(path) ~ ".hikari-backup-*", SpanMode.shallow)) backups ~= e.name;
    sort(backups);
    if (backups.length > keep) foreach (old; backups[0 .. $ - keep]) { try { remove(old); } catch (Exception) {} }
    return dest;
}

/// Replaces `path` with `text` atomically, keeping the original owner, mode and ACL.
void atomicReplace(string path, string text) @trusted {
    import std.file : exists, remove, rename, write;
    import std.path : baseName, buildPath, dirName;
    auto tmp = buildPath(dirName(path), "." ~ baseName(path) ~ ".hikari-tmp");
    write(tmp, text);
    scope (failure) { try { if (exists(tmp)) remove(tmp); } catch (Exception) {} }
    if (!exists(path)) {
        rename(tmp, path);
        return;
    }
    version (Posix) {
        import core.sys.posix.sys.stat : chmod, stat, stat_t;
        import core.sys.posix.unistd : chown;
        import std.string : toStringz;
        stat_t st;
        if (stat(path.toStringz(), &st) == 0) {
            chmod(tmp.toStringz(), st.st_mode & octal!7777);
            chown(tmp.toStringz(), st.st_uid, st.st_gid); // best effort (needs root for others' files)
        }
        rename(tmp, path);
    } else version (Windows) {
        import std.utf : toUTF16z;
        // ReplaceFileW keeps the replaced file's ACL, owner and attributes.
        if (!ReplaceFileW(path.toUTF16z(), tmp.toUTF16z(), null, 0, null, null)) {
            throw new IntegrationError("could not replace " ~ path ~ " atomically");
        }
    } else {
        rename(tmp, path);
    }
}

version (Windows) {
    private extern (Windows) nothrow @nogc int ReplaceFileW(const(wchar)*, const(wchar)*, const(wchar)*, uint, void*, void*);
}

private template octal(uint n) {
    enum uint octal = () {
        uint v = 0, mul = 1, x = n;
        while (x > 0) { v += (x % 10) * mul; mul *= 8; x /= 10; }
        return v;
    }();
}
