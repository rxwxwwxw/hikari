module caddyfile.parser;

// Caddyfile structure parser. Produces a tree of server blocks and directives with byte
// spans; it never rewrites source text. A loader follows `import` statements (snippets
// and file globs relative to the importing file) with a cycle guard and depth limit.

import caddyfile.lexer;
import std.algorithm : canFind, endsWith, sort, startsWith;
import std.array : array;
import std.string : strip;

struct Directive {
    string name;
    string[] args;
    uint line;
    size_t start;          // first byte of the directive name
    size_t end;            // one past the last byte (incl. closing brace of a block)
    bool hasBlock;
    Directive[] block;
    string file;
}

enum BlockKind { global, snippet, namedRoute, site }

struct ServerBlock {
    BlockKind kind;
    string[] keys;          // site addresses, or the snippet/route name
    bool braced;
    uint line;
    size_t start;
    size_t end;
    Directive[] body;
    string file;
}

struct ImportRef {
    string pattern;
    string[] args;
    bool topLevel;          // between server blocks (vs. inside a block)
    uint line;
    size_t start;
    size_t end;             // one past the last arg on the line
    string file;            // file containing the import
}

struct ParsedFile {
    string path;
    string src;
    LexResult lex;
    ServerBlock[] blocks;
    ImportRef[] imports;    // top-level and in-block
}

private struct Cursor {
    Token[] toks;
    size_t pos;
    string file;

    bool done() const pure nothrow @safe { return pos >= toks.length; }
    ref const(Token) cur() const pure nothrow @safe { return toks[pos]; }
}

/// Parses one Caddyfile (no import resolution). Throws CaddyfileSyntaxError.
ParsedFile parseCaddyfile(string src, string path = "") @safe {
    ParsedFile pf;
    pf.path = path;
    pf.src = src;
    pf.lex = lexCaddyfile(src, path);
    auto c = Cursor(pf.lex.tokens, 0, path);

    // Global options block: a first block with no keys.
    if (!c.done() && c.cur().isOpen()) {
        ServerBlock g;
        g.kind = BlockKind.global;
        g.braced = true;
        g.line = c.cur().line;
        g.start = c.cur().start;
        g.file = path;
        c.pos++;
        g.body = parseDirectives(c, true, pf.imports);
        g.end = c.toks[c.pos].end;
        c.pos++;
        pf.blocks ~= g;
    }

    while (!c.done()) {
        auto t = c.cur();
        if (t.isClose()) throw new CaddyfileSyntaxError("unexpected '}'", path, t.line);
        if (t.isOpen()) throw new CaddyfileSyntaxError("unexpected '{' (global options must be the first block)", path, t.line);

        // Top-level import: `import pattern [args...]` alone on its line(s).
        if (!t.quoted && t.text == "import" && !opensBlockOnLine(c)) {
            ImportRef imp;
            imp.topLevel = true;
            imp.line = t.line;
            imp.start = t.start;
            imp.file = path;
            uint lineEnd = t.endLine;
            c.pos++;
            if (c.done() || c.cur().line > lineEnd) throw new CaddyfileSyntaxError("import requires a file or snippet name", path, t.line);
            imp.end = t.end;
            while (!c.done() && c.cur().line <= lineEnd) {
                if (imp.pattern.length == 0) imp.pattern = c.cur().text;
                else imp.args ~= c.cur().text;
                lineEnd = c.cur().endLine;
                imp.end = c.cur().end;
                c.pos++;
            }
            pf.imports ~= imp;
            continue;
        }

        ServerBlock b;
        b.line = t.line;
        b.start = t.start;
        b.file = path;
        // Keys: on the same line, or continued onto following lines after a trailing comma.
        while (!c.done()) {
            auto k = c.cur();
            if (k.isOpen()) break;
            if (k.isClose()) throw new CaddyfileSyntaxError("unexpected '}' in site address list", path, k.line);
            bool trailingComma = k.text.endsWith(",");
            foreach (part; splitKeys(k.text)) b.keys ~= part;
            c.pos++;
            if (c.done()) break;
            if (c.cur().isOpen()) break;
            if (c.cur().line > k.endLine && !trailingComma) break;
        }
        b.kind = classifyKeys(b.keys);
        if (!c.done() && c.cur().isOpen()) {
            b.braced = true;
            c.pos++;
            b.body = parseDirectives(c, true, pf.imports);
            b.end = c.toks[c.pos].end;
            c.pos++;
        } else {
            // A brace-less site block must be the only one; the rest of the file is its body.
            bool othersExist = false;
            foreach (ob; pf.blocks) if (ob.kind != BlockKind.global) othersExist = true;
            if (othersExist) throw new CaddyfileSyntaxError("site block without braces must be the only site block", path, b.line);
            b.body = parseDirectives(c, false, pf.imports);
            b.end = c.done() ? (c.toks.length > 0 ? c.toks[$ - 1].end : b.start) : c.cur().end;
        }
        pf.blocks ~= b;
    }
    return pf;
}

/// Parses a file that is imported inside a block: directives only.
ParsedFile parseDirectiveFile(string src, string path = "") @safe {
    ParsedFile pf;
    pf.path = path;
    pf.src = src;
    pf.lex = lexCaddyfile(src, path);
    auto c = Cursor(pf.lex.tokens, 0, path);
    ServerBlock b;
    b.kind = BlockKind.snippet;
    b.file = path;
    b.body = parseDirectives(c, false, pf.imports);
    pf.blocks ~= b;
    return pf;
}

private string[] splitKeys(string tok) pure @safe {
    string[] r;
    size_t s = 0;
    foreach (i, ch; tok) {
        if (ch == ',') {
            if (i > s) r ~= tok[s .. i];
            s = i + 1;
        }
    }
    if (s < tok.length) r ~= tok[s .. $];
    return r;
}

private BlockKind classifyKeys(const string[] keys) pure @safe {
    if (keys.length == 1) {
        auto k = keys[0];
        if (k.startsWith("&(") && k.endsWith(")")) return BlockKind.namedRoute;
        if (k.startsWith("(") && k.endsWith(")")) return BlockKind.snippet;
    }
    return BlockKind.site;
}

/// True if the current statement (tokens on the current logical line) ends with `{`.
private bool opensBlockOnLine(const ref Cursor c) pure nothrow @safe {
    size_t p = c.pos;
    uint lineEnd = c.toks[p].endLine;
    p++;
    while (p < c.toks.length && c.toks[p].line <= lineEnd) {
        if (c.toks[p].isOpen()) return true;
        lineEnd = c.toks[p].endLine;
        p++;
    }
    return false;
}

private Directive[] parseDirectives(ref Cursor c, bool untilBrace, ref ImportRef[] imports) @safe {
    Directive[] ds;
    while (!c.done()) {
        auto t = c.cur();
        if (t.isClose()) {
            if (untilBrace) return ds;
            throw new CaddyfileSyntaxError("unexpected '}'", c.file, t.line);
        }
        if (t.isOpen()) throw new CaddyfileSyntaxError("unexpected '{' (a block must follow a directive on the same line)", c.file, t.line);

        Directive d;
        d.name = t.text;
        d.line = t.line;
        d.start = t.start;
        d.end = t.end;
        d.file = c.file;
        uint lineEnd = t.endLine;
        c.pos++;
        while (!c.done() && c.cur().line <= lineEnd) {
            auto a = c.cur();
            if (a.isOpen()) {
                // A block opener must be the last token on its line.
                bool last = c.pos + 1 >= c.toks.length || c.toks[c.pos + 1].line > a.endLine;
                if (!last) throw new CaddyfileSyntaxError("'{' must be the last token on its line", c.file, a.line);
                c.pos++;
                d.hasBlock = true;
                d.block = parseDirectives(c, true, imports);
                if (c.done()) throw new CaddyfileSyntaxError("block opened by '" ~ d.name ~ "' is never closed", c.file, d.line);
                d.end = c.cur().end;
                c.pos++;
                break;
            }
            if (a.isClose()) break; // `directive arg }` closes the enclosing block
            d.args ~= a.text;
            d.end = a.end;
            lineEnd = a.endLine;
            c.pos++;
        }
        if (d.name == "import" && d.args.length > 0) {
            imports ~= ImportRef(d.args[0], d.args[1 .. $].dup, false, d.line, d.start, d.end, c.file);
        }
        ds ~= d;
    }
    if (untilBrace) {
        uint lastLine = c.toks.length > 0 ? c.toks[$ - 1].line : 0;
        throw new CaddyfileSyntaxError("missing '}' (unclosed block)", c.file, lastLine);
    }
    return ds;
}

// ---------------------------------------------------------------------------
// Import-following loader
// ---------------------------------------------------------------------------

struct ImportIssue {
    string file;
    uint line;
    string pattern;
    string problem;   // "unsupported_glob", "depth_limit", "cycle"
}

struct CaddyConfigTree {
    ParsedFile main;
    ParsedFile[] included;       // files pulled in by imports (top-level and in-block)
    string[string] snippetOwner; // snippet name -> file
    ServerBlock[string] snippets;
    ImportIssue[] issues;

    /// All server blocks from the main file and top-level imported files.
    ServerBlock[] allBlocks() @safe {
        ServerBlock[] r = main.blocks.dup;
        foreach (f; included) foreach (b; f.blocks) if (b.kind != BlockKind.snippet || b.keys.length > 0) r ~= b;
        return r;
    }
}

alias FileReader = string delegate(string path) @safe;
alias GlobLister = string[] delegate(string dir, string pattern) @safe;

private bool hasWildcard(string s) pure nothrow @safe {
    foreach (ch; s) if (ch == '*' || ch == '?' || ch == '[') return true;
    return false;
}

/// Resolves an import pattern relative to the importing file. Returns the matching files
/// (sorted, like Go's filepath.Glob), or sets `issue` for patterns we cannot evaluate.
string[] resolveImportPattern(string importingFile, string pattern, GlobLister lister, out string issue) @safe {
    import std.path : baseName, buildNormalizedPath, dirName, isAbsolute;
    issue = "";
    string full = isAbsolute(pattern) ? pattern : buildNormalizedPath(dirName(importingFile), pattern);
    if (!hasWildcard(pattern)) return [full];
    auto dir = dirName(full);
    auto pat = baseName(full);
    if (hasWildcard(dir)) {
        issue = "unsupported_glob";
        return null;
    }
    auto found = lister(dir, pat);
    sort(found);
    return found;
}

private string[] defaultGlobLister(string dir, string pattern) @trusted {
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : baseName, globMatch;
    string[] r;
    if (!exists(dir) || !isDir(dir)) return r;
    foreach (e; dirEntries(dir, SpanMode.shallow)) {
        if (e.isFile && globMatch(baseName(e.name), pattern)) r ~= e.name;
    }
    return r;
}

private string defaultReader(string path) @trusted {
    import std.file : readText;
    return readText(path);
}

/// Loads a Caddyfile and everything it imports. Parse errors propagate as exceptions.
CaddyConfigTree loadCaddyConfig(string mainPath, FileReader reader = null, GlobLister lister = null, uint maxDepth = 16) @safe {
    import std.functional : toDelegate;
    import std.path : absolutePath, buildNormalizedPath;
    if (reader is null) reader = toDelegate(&defaultReader);
    if (lister is null) lister = toDelegate(&defaultGlobLister);

    CaddyConfigTree tree;
    auto mainAbs = buildNormalizedPath(absolutePath(mainPath));
    tree.main = parseCaddyfile(reader(mainAbs), mainAbs);
    bool[string] seen;
    seen[mainAbs] = true;

    void collectSnippets(ParsedFile pf) {
        foreach (b; pf.blocks) {
            if (b.kind == BlockKind.snippet && b.keys.length == 1) {
                auto name = b.keys[0][1 .. $ - 1];
                tree.snippets[name] = b;
                tree.snippetOwner[name] = pf.path;
            }
        }
    }

    bool[string] onStack;
    onStack[mainAbs] = true;

    void follow(ParsedFile pf, uint depth) {
        collectSnippets(pf);
        foreach (imp; pf.imports) {
            if (imp.pattern in tree.snippets) continue; // snippet import
            if (depth >= maxDepth) {
                tree.issues ~= ImportIssue(pf.path, imp.line, imp.pattern, "depth_limit");
                continue;
            }
            string issue;
            auto files = resolveImportPattern(pf.path, imp.pattern, lister, issue);
            if (issue.length > 0) {
                tree.issues ~= ImportIssue(pf.path, imp.line, imp.pattern, issue);
                continue;
            }
            foreach (f; files) {
                if (f in onStack) {
                    // Caddy rejects import cycles; record it so the verdict refuses.
                    tree.issues ~= ImportIssue(pf.path, imp.line, imp.pattern, "cycle");
                    continue;
                }
                if (f in seen) {
                    // Same file imported twice (diamond): Caddy would see its sites twice.
                    tree.issues ~= ImportIssue(pf.path, imp.line, imp.pattern, "duplicate_import");
                    continue;
                }
                seen[f] = true;
                string text;
                try {
                    text = reader(f);
                } catch (Exception e) {
                    throw new CaddyfileSyntaxError("import file not found or unreadable: " ~ imp.pattern, pf.path, imp.line);
                }
                auto child = imp.topLevel ? parseCaddyfile(text, f) : parseDirectiveFile(text, f);
                tree.included ~= child;
                onStack[f] = true;
                follow(child, depth + 1);
                onStack.remove(f);
            }
        }
    }

    // Snippets can be defined after their first use in import order; collect up front.
    collectSnippets(tree.main);
    follow(tree.main, 0);
    return tree;
}
