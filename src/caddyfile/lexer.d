module caddyfile.lexer;

// Lossless Caddyfile tokenizer that follows Caddy's own lexer rules closely enough to
// analyse real-world configs without ever re-serializing them. Every token records its
// exact byte span in the source so later edits can be made by offset, leaving all other
// bytes untouched.
//
// Rules mirrored from Caddy's caddyfile lexer:
//   * tokens are separated by whitespace; newlines matter to the parser (line numbers);
//   * `#` begins a comment only at the start of a token (`foo#bar` is one token);
//   * a double quote at the start of a token opens a quoted token that may span lines;
//     inside it `\"` is a literal quote, any other backslash is kept;
//   * a backtick at the start of a token opens a raw token (no escapes);
//   * `<<MARKER` at the end of a line opens a heredoc closed by a line containing only
//     MARKER; the closing line's indentation is stripped from every content line;
//   * `{` and `}` are ordinary tokens; the parser gives them meaning when unquoted.
// Environment placeholders `{$VAR}` / `{$VAR:default}` are kept literally and flagged.

import std.string : indexOf, strip;

struct Token {
    string text;      // value after quote/escape processing
    size_t start;     // byte offset of the first source byte (incl. opening quote)
    size_t end;       // byte offset one past the last source byte
    uint line;        // 1-based line where the token starts
    uint endLine;     // line where the token ends (differs for multi-line quotes/heredocs)
    bool quoted;      // double-quoted, backtick or heredoc
    bool heredoc;
    bool envPlaceholder;

    bool isOpen() const pure nothrow @safe { return !quoted && text == "{"; }
    bool isClose() const pure nothrow @safe { return !quoted && text == "}"; }
}

struct Comment {
    string text;      // without the leading '#', trailing CR stripped
    size_t start;
    size_t end;
    uint line;
}

struct LexResult {
    Token[] tokens;
    Comment[] comments;
    bool hasBom;
    bool crlf;        // first line ending is CRLF
}

class CaddyfileSyntaxError : Exception {
    string file;
    uint line;
    this(string msg, string file, uint line) pure @safe {
        import std.format : format;
        super(file.length > 0 ? format!"%s:%u: %s"(file, line, msg) : format!"line %u: %s"(line, msg));
        this.file = file;
        this.line = line;
    }
}

private bool isSpace(char c) pure nothrow @safe @nogc {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

private bool isMarkerChar(char c) pure nothrow @safe @nogc {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

LexResult lexCaddyfile(string src, string file = "") @safe {
    LexResult r;
    size_t i = 0;
    immutable n = src.length;
    if (n >= 3 && src[0 .. 3] == "\xEF\xBB\xBF") {
        r.hasBom = true;
        i = 3;
    }
    auto firstNl = src.indexOf('\n');
    r.crlf = firstNl > 0 && src[firstNl - 1] == '\r';

    uint line = 1;
    while (i < n) {
        // Skip whitespace.
        while (i < n && isSpace(src[i])) {
            if (src[i] == '\n') line++;
            i++;
        }
        if (i >= n) break;

        char c = src[i];

        if (c == '#') {
            size_t s = i;
            while (i < n && src[i] != '\n') i++;
            auto text = src[s + 1 .. i];
            if (text.length > 0 && text[$ - 1] == '\r') text = text[0 .. $ - 1];
            r.comments ~= Comment(text, s, i, line);
            continue;
        }

        Token t;
        t.start = i;
        t.line = line;

        if (c == '"') {
            t.quoted = true;
            i++;
            string buf;
            bool closed = false;
            while (i < n) {
                char q = src[i];
                if (q == '\\' && i + 1 < n && src[i + 1] == '"') {
                    buf ~= '"';
                    i += 2;
                    continue;
                }
                if (q == '"') {
                    i++;
                    closed = true;
                    break;
                }
                if (q == '\n') line++;
                buf ~= q;
                i++;
            }
            if (!closed) throw new CaddyfileSyntaxError("unterminated quoted string", file, t.line);
            t.text = buf;
        } else if (c == '`') {
            t.quoted = true;
            i++;
            size_t s = i;
            while (i < n && src[i] != '`') {
                if (src[i] == '\n') line++;
                i++;
            }
            if (i >= n) throw new CaddyfileSyntaxError("unterminated backtick string", file, t.line);
            t.text = src[s .. i];
            i++;
        } else if (c == '<' && i + 2 < n && src[i + 1] == '<' && isMarkerChar(src[i + 2]) && heredocStartsHere(src, i)) {
            // Heredoc: <<MARKER followed by end of line.
            size_t m = i + 2;
            while (m < n && isMarkerChar(src[m])) m++;
            string marker = src[i + 2 .. m];
            size_t p = m;
            if (p < n && src[p] == '\r') p++;
            p++; // the '\n'
            line++;
            string[] lines;
            bool closed = false;
            size_t closeEnd = p;
            string indent;
            while (p <= n) {
                size_t le = p;
                while (le < n && src[le] != '\n') le++;
                auto raw = src[p .. le];
                if (raw.length > 0 && raw[$ - 1] == '\r') raw = raw[0 .. $ - 1];
                // Closing line: optional indentation, the marker, then end of line or more
                // tokens on the same line (e.g. `HTML 200` passes 200 as the next argument).
                size_t k = 0;
                while (k < raw.length && (raw[k] == ' ' || raw[k] == '\t')) k++;
                auto afterIndent = raw[k .. $];
                if (afterIndent.length >= marker.length && afterIndent[0 .. marker.length] == marker
                        && (afterIndent.length == marker.length || afterIndent[marker.length] == ' ' || afterIndent[marker.length] == '\t')) {
                    indent = raw[0 .. k];
                    closeEnd = p + k + marker.length;
                    closed = true;
                    break;
                }
                lines ~= raw;
                if (le >= n) break;
                p = le + 1;
                line++;
            }
            if (!closed) throw new CaddyfileSyntaxError("heredoc <<" ~ marker ~ " is not closed", file, t.line);
            string text;
            foreach (idx, l; lines) {
                if (idx > 0) text ~= "\n";
                if (indent.length > 0) {
                    if (l.length >= indent.length && l[0 .. indent.length] == indent) {
                        l = l[indent.length .. $];
                    } else if (l.strip().length > 0) {
                        throw new CaddyfileSyntaxError("heredoc line is not indented like its closing marker", file, line);
                    }
                }
                text ~= l;
            }
            t.text = text;
            t.quoted = true;
            t.heredoc = true;
            i = closeEnd;
        } else {
            size_t s = i;
            while (i < n && !isSpace(src[i])) i++;
            t.text = src[s .. i];
        }

        t.end = i;
        t.endLine = line;
        t.envPlaceholder = t.text.indexOf("{$") >= 0;
        r.tokens ~= t;
    }
    return r;
}

/// `<<MARKER` opens a heredoc only when nothing but whitespace follows it on the line.
private bool heredocStartsHere(string src, size_t i) pure nothrow @safe @nogc {
    size_t m = i + 2;
    while (m < src.length && isMarkerChar(src[m])) m++;
    while (m < src.length && (src[m] == ' ' || src[m] == '\t')) m++;
    return m >= src.length || src[m] == '\n' || src[m] == '\r';
}
