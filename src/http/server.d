module http.server;

import core.atomic;
import core.config : isLoopbackBindAddress;
import core.limits;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time : MonoTime, msecs;
import http.routes;
import http.security;
import std.conv : to;
import std.format : format;
import std.socket;
import std.string : indexOf, strip, toLower;

version (Posix) {
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.sys.socket : accept, MSG_NOSIGNAL, recv, send, setsockopt, shutdown, SHUT_RDWR, SO_RCVTIMEO, SO_SNDTIMEO, SOL_SOCKET;
    import core.sys.posix.sys.time : timeval;
    import core.sys.posix.unistd : posixClose = close;
}
version (Windows) {
    import core.sys.windows.winsock2 : accept, closesocket, DWORD, INVALID_SOCKET, recv, send, setsockopt, shutdown, SD_BOTH, SO_EXCLUSIVEADDRUSE, SO_RCVTIMEO, SO_SNDTIMEO, SOCKET, SOCKET_ERROR, SOL_SOCKET;
}

private pure nothrow @nogc @safe {

bool isAsciiWs(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

char lowerAscii(char c) {
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

string trimAsciiSlice(string s) {
    size_t start = 0;
    while (start < s.length && isAsciiWs(s[start])) start++;
    size_t end = s.length;
    while (end > start && isAsciiWs(s[end - 1])) end--;
    return s[start .. end];
}

bool eqIgnoreCase(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        if (lowerAscii(a[i]) != lowerAscii(b[i])) return false;
    }
    return true;
}

ptrdiff_t findHeaderEnd(const(char)[] buf) {
    if (buf.length < 2) return -1;
    foreach (i; 0 .. buf.length) {
        if (i + 3 < buf.length && buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') {
            return cast(ptrdiff_t) i;
        }
        if (i + 1 < buf.length && buf[i] == '\n' && buf[i + 1] == '\n') {
            return cast(ptrdiff_t) i;
        }
    }
    return -1;
}

} // private @nogc helpers

private enum ParseHttpStatus {
    ok,
    empty,
    malformed,
    uriTooLong,
}

private ParseHttpStatus parseHttpRequestStatus(string raw, out HttpRequest req) pure nothrow @nogc @safe {
    auto headerEnd = findHeaderEnd(raw);
    auto head = headerEnd >= 0 ? raw[0 .. headerEnd] : raw;

    size_t lineStart = 0;
    size_t nl = 0;
    while (nl < head.length && head[nl] != '\n') nl++;
    if (nl == 0 && head.length == 0) return ParseHttpStatus.empty;

    auto reqLine = trimAsciiSlice(head[lineStart .. nl]);
    if (reqLine.length == 0) return ParseHttpStatus.empty;

    size_t sp1 = 0;
    while (sp1 < reqLine.length && reqLine[sp1] != ' ') sp1++;
    if (sp1 >= reqLine.length) return ParseHttpStatus.malformed;

    auto methodSlice = trimAsciiSlice(reqLine[0 .. sp1]);
    size_t sp2Start = sp1 + 1;
    size_t sp2 = sp2Start;
    while (sp2 < reqLine.length && reqLine[sp2] != ' ') sp2++;
    auto targetSlice = trimAsciiSlice(reqLine[sp2Start .. sp2]);
    if (methodSlice.length == 0 || targetSlice.length == 0) return ParseHttpStatus.malformed;
    if (targetSlice.length > MAX_URI_LENGTH) return ParseHttpStatus.uriTooLong;

    req.method = methodSlice;
    ptrdiff_t qIdx = -1;
    foreach (i, char c; targetSlice) {
        if (c == '?') {
            qIdx = cast(ptrdiff_t) i;
            break;
        }
    }
    if (qIdx >= 0) {
        req.path = targetSlice[0 .. qIdx];
        req.query = targetSlice[qIdx + 1 .. $];
    } else {
        req.path = targetSlice;
        req.query = "";
    }

    size_t pos = nl + 1;
    while (pos <= head.length && nl < head.length) {
        size_t end = pos;
        while (end < head.length && head[end] != '\n') end++;
        auto clean = trimAsciiSlice(head[pos .. end]);
        pos = end + 1;
        if (clean.length == 0) continue;

        ptrdiff_t colon = -1;
        foreach (i, char c; clean) {
            if (c == ':') {
                colon = cast(ptrdiff_t) i;
                break;
            }
        }
        if (colon <= 0) continue;
        auto k = trimAsciiSlice(clean[0 .. colon]);
        auto v = trimAsciiSlice(clean[colon + 1 .. $]);
        if (eqIgnoreCase(k, "host")) {
            req.hasHostHeader = true;
            req.hostHeader = v;
        } else if (eqIgnoreCase(k, "origin")) {
            req.originHeader = v;
        }
        if (end >= head.length) break;
    }

    return ParseHttpStatus.ok;
}

bool parseHttpRequestInPlace(string raw, out HttpRequest req) pure nothrow @nogc @safe {
    return parseHttpRequestStatus(raw, req) == ParseHttpStatus.ok;
}

HttpRequest parseRawHttpRequest(string raw) {
    HttpRequest req;
    final switch (parseHttpRequestStatus(raw, req)) {
        case ParseHttpStatus.ok: break;
        case ParseHttpStatus.empty: throw new Exception("Empty request");
        case ParseHttpStatus.malformed: throw new Exception("Malformed request line");
        case ParseHttpStatus.uriTooLong: throw new Exception("URI too long");
    }

    auto headerEnd = findHeaderEnd(raw);
    auto head = headerEnd >= 0 ? raw[0 .. headerEnd] : raw;
    auto firstNl = head.indexOf('\n');
    if (firstNl >= 0 && firstNl + 1 < head.length) {
        size_t pos = cast(size_t)(firstNl + 1);
        while (pos < head.length) {
            auto nextNl = head[pos .. $].indexOf('\n');
            size_t end = nextNl >= 0 ? pos + cast(size_t) nextNl : head.length;
            auto clean = head[pos .. end].strip();
            pos = end + 1;
            if (clean.length == 0) continue;
            auto colon = clean.indexOf(':');
            if (colon <= 0) continue;
            auto k = clean[0 .. colon].strip().toLower();
            auto v = clean[colon + 1 .. $].strip();
            req.headers[k] = v;
        }
    }
    return req;
}

private struct HttpHeaderWriter {
    char[] buf;
    size_t pos = 0;
    bool overflow = false;

    @nogc nothrow @safe:

    void put(const(char)[] s) {
        if (overflow || s.length == 0) return;
        if (pos + s.length > buf.length) {
            overflow = true;
            return;
        }
        buf[pos .. pos + s.length] = s[];
        pos += s.length;
    }

    void putUint(size_t v) {
        char[24] tmp = void;
        size_t p = 0;
        do {
            tmp[p++] = cast(char)('0' + (v % 10));
            v /= 10;
        } while (v > 0);
        if (pos + p > buf.length) {
            overflow = true;
            return;
        }
        foreach (i; 0 .. p) {
            buf[pos++] = tmp[p - 1 - i];
        }
    }

    const(char)[] slice() const return {
        return buf[0 .. pos];
    }
}

private bool formatHttpResponseHeadersInto(
    char[] hdrBuf,
    const ref HttpResponse resp,
    size_t contentLen,
    out size_t hdrLen
) @nogc nothrow @safe {
    auto w = HttpHeaderWriter(hdrBuf);
    w.put("HTTP/1.1 ");
    w.putUint(resp.statusCode >= 0 ? cast(size_t) resp.statusCode : 500);
    w.put(" ");
    w.put(resp.statusText);
    w.put("\r\nContent-Type: ");
    w.put(resp.contentType);
    w.put("\r\nContent-Length: ");
    w.putUint(contentLen);
    w.put("\r\nConnection: close\r\n");
    w.put("X-Content-Type-Options: nosniff\r\n");
    w.put("Cache-Control: no-store\r\n");
    if (resp.corsAllowOrigin.length > 0) {
        w.put("Access-Control-Allow-Origin: ");
        w.put(resp.corsAllowOrigin);
        w.put("\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n");
    }
    if (resp.retryAfter.length > 0) {
        w.put("Retry-After: ");
        w.put(resp.retryAfter);
        w.put("\r\n");
    }
    if (resp.cspHeader.length > 0) {
        w.put("Content-Security-Policy: ");
        w.put(resp.cspHeader);
        w.put("\r\n");
    }
    if (resp.headers.length > 0) {
        foreach (k, v; resp.headers) {
            w.put(k);
            w.put(": ");
            w.put(v);
            w.put("\r\n");
        }
    }
    w.put("\r\n");
    hdrLen = w.pos;
    return !w.overflow;
}

string formatRawHttpResponse(const ref HttpResponse resp, bool headOnly = false) {
    import std.array : appender;
    auto app = appender!string();
    app.put(format!"HTTP/1.1 %d %s\r\n"(resp.statusCode, resp.statusText));
    app.put(format!"Content-Type: %s\r\n"(resp.contentType));
    app.put(format!"Content-Length: %u\r\n"(resp.bodyText.length));
    app.put("Connection: close\r\n");
    if (resp.corsAllowOrigin.length > 0 && "Access-Control-Allow-Origin" !in resp.headers) {
        app.put("Access-Control-Allow-Origin: " ~ resp.corsAllowOrigin ~ "\r\n");
        app.put("Vary: Origin\r\n");
        app.put("Access-Control-Allow-Methods: GET, OPTIONS\r\n");
        app.put("Access-Control-Allow-Headers: Content-Type\r\n");
    }
    if (resp.retryAfter.length > 0 && "Retry-After" !in resp.headers) {
        app.put("Retry-After: " ~ resp.retryAfter ~ "\r\n");
    }
    if (resp.cspHeader.length > 0 && "Content-Security-Policy" !in resp.headers) {
        app.put("Content-Security-Policy: " ~ resp.cspHeader ~ "\r\n");
    }
    foreach (k, v; resp.headers) {
        app.put(k ~ ": " ~ v ~ "\r\n");
    }
    app.put("\r\n");
    if (!headOnly && resp.bodyText.length > 0) {
        app.put(resp.bodyText);
    }
    return app.data;
}

class LoopbackHttpServer {
    string bindAddr;
    ushort port;
    HikariRouter router;
    void delegate() dashboardResponseCompleted;

    private enum size_t QUEUE_CAP = 1024;
    private enum socket_t INVALID_FD = cast(socket_t) -1;

    private TcpSocket listener;
    private shared bool running = false;
    private shared size_t rawHandle = size_t.max;
    private ushort boundPort = 0;
    private shared uint clients = 0;
    private uint maxClients;
    private uint workerCount;

    private Mutex qMtx;
    private Condition qCond;
    private socket_t[QUEUE_CAP] pendingQueue;
    private size_t qHead = 0;
    private size_t qTail = 0;
    private size_t qCount = 0;
    private Thread[MAX_HTTP_WORKERS] workerThreads;
    private bool workersStarted = false;

    uint activeClients() { return atomicLoad(clients); }

    this(string bindAddr, ushort port, HikariRouter router, uint maxClients = 32) {
        if (!maxClients || maxClients > 1024) throw new Exception("Invalid HTTP client limit");
        this.maxClients = maxClients;
        this.workerCount = maxClients < MAX_HTTP_WORKERS ? maxClients : MAX_HTTP_WORKERS;
        if (!isLoopbackBindAddress(bindAddr)) {
            throw new Exception("Security violation: HTTP server refuses non-loopback bind address: " ~ bindAddr);
        }
        this.bindAddr = bindAddr == "localhost" ? "127.0.0.1" : bindAddr;
        this.port = port;
        this.router = router;
        this.qMtx = new Mutex();
        this.qCond = new Condition(this.qMtx);
    }

    ushort actualPort() const nothrow @safe {
        return boundPort;
    }

    private void ensureWorkersStarted() {
        synchronized (qMtx) {
            if (workersStarted) return;
            workersStarted = true;
            foreach (i; 0 .. workerCount) {
                auto t = new Thread(&workerLoop);
                t.isDaemon = true;
                workerThreads[i] = t;
                t.start();
            }
        }
    }

    void startListening() {
        Address addr;
        if (bindAddr == "::1") {
            addr = new Internet6Address("::1", port);
            listener = new TcpSocket(AddressFamily.INET6);
        } else {
            addr = new InternetAddress(bindAddr, port);
            listener = new TcpSocket(AddressFamily.INET);
        }
        version (Windows) {
            // On Windows SO_REUSEADDR lets a second process steal an in-use port.
            // SO_EXCLUSIVEADDRUSE guarantees the loopback port really belongs to hikari.
            int one = 1;
            if (setsockopt(listener.handle, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, cast(const(char)*) &one, int.sizeof) != 0) {
                throw new Exception("Unable to set SO_EXCLUSIVEADDRUSE on loopback listener");
            }
        } else {
            listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        }
        listener.bind(addr);
        listener.listen(64);
        listener.blocking = true;
        boundPort = to!ushort(listener.localAddress().toPortString());
        atomicStore(rawHandle, cast(size_t) listener.handle);
        atomicStore(running, true);
        ensureWorkersStarted();
    }

    /// Async-signal/console-handler safe stop: no GC, no exceptions. Closing the raw
    /// listening socket unblocks accept() so serveLoop() returns.
    void requestStop() nothrow @nogc {
        atomicStore(running, false);
        auto h = atomicExchange(&rawHandle, size_t.max);
        if (h == size_t.max) return;
        version (Windows) {
            closesocket(cast(SOCKET) h);
        } else {
            shutdown(cast(int) h, SHUT_RDWR);
        }
    }

    private void admitClient(socket_t cfd) {
        // Only the accept loop admits clients. Reject overload before queueing;
        // closing here never blocks accept on a slow client's writes.
        if (atomicLoad(clients) >= maxClients) {
            closeFdQuietly(cfd);
            return;
        }
        atomicOp!"+="(clients, 1);
        bool enqueued = false;
        synchronized (qMtx) {
            if (atomicLoad(running) && qCount < QUEUE_CAP) {
                pendingQueue[qTail] = cfd;
                qTail = (qTail + 1) % QUEUE_CAP;
                qCount++;
                enqueued = true;
                qCond.notify();
            }
        }
        if (!enqueued) {
            atomicOp!"-="(clients, 1);
            closeFdQuietly(cfd);
        }
    }

    private void workerLoop() {
        auto bodyBuf = new char[HTTP_RESPONSE_BUF_SIZE];
        while (true) {
            socket_t cfd = INVALID_FD;
            synchronized (qMtx) {
                while (qCount == 0 && atomicLoad(running)) {
                    qCond.wait();
                }
                if (qCount == 0 && !atomicLoad(running)) {
                    return;
                }
                cfd = pendingQueue[qHead];
                qHead = (qHead + 1) % QUEUE_CAP;
                qCount--;
            }
            handleConnectionFd(cfd, bodyBuf);
        }
    }

    void serveLoop() {
        if (listener is null) startListening();
        scope (exit) {
            synchronized (qMtx) qCond.notifyAll();
        }
        while (atomicLoad(running)) {
            auto h = atomicLoad(rawHandle);
            if (h == size_t.max) break;
            version (Windows) {
                SOCKET cfd = accept(cast(SOCKET) h, null, null);
                if (cfd == INVALID_SOCKET) {
                    if (!atomicLoad(running)) break;
                    Thread.sleep(msecs(1));
                    continue;
                }
                admitClient(cast(socket_t) cfd);
            } else {
                int cfd = accept(cast(int) h, null, null);
                if (cfd < 0) {
                    if (!atomicLoad(running)) break;
                    if (errno == EINTR) continue;
                    Thread.sleep(msecs(1));
                    continue;
                }
                static if (__traits(compiles, SO_NOSIGPIPE)) {
                    int one = 1;
                    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, one.sizeof);
                }
                admitClient(cast(socket_t) cfd);
            }
        }
    }

    // Called after stopping acceptance. An external update supervisor waits for
    // the service to stop before starting the replacement, preserving responses.
    void drainClients() {
        synchronized (qMtx) qCond.notifyAll();
        while (atomicLoad(clients)) Thread.sleep(msecs(10));
    }

    Thread startBackground() {
        startListening();
        auto t = new Thread(&serveLoop);
        t.isDaemon = true;
        t.start();
        return t;
    }

    void stop() {
        atomicStore(running, false);
        atomicStore(rawHandle, size_t.max);
        if (listener !is null) {
            try { listener.shutdown(SocketShutdown.BOTH); } catch (Exception) {}
            try { listener.close(); } catch (Exception) {}
        }
        synchronized (qMtx) {
            while (qCount > 0) {
                closeFdQuietly(pendingQueue[qHead]);
                qHead = (qHead + 1) % QUEUE_CAP;
                qCount--;
                atomicOp!"-="(clients, 1);
            }
            qCond.notifyAll();
        }
    }

    private void handleConnectionFd(socket_t cfd, char[] bodyBuf) {
        scope (exit) {
            closeFdQuietly(cfd);
            atomicOp!"-="(clients, 1);
        }
        try {
            setTimeoutMs(cfd, true, 3000);
            setTimeoutMs(cfd, false, 5000);

            char[MAX_REQUEST_BYTES + 1] buf = void;
            size_t total = 0;
            bool headersComplete = false;

            auto headerDeadline = MonoTime.currTime + msecs(3000);
            while (total < MAX_REQUEST_BYTES) {
                auto remainingMs = (headerDeadline - MonoTime.currTime).total!"msecs"();
                if (remainingMs <= 1) return;
                setTimeoutMs(cfd, true, remainingMs);
                auto n = rawRecv(cfd, buf.ptr + total, MAX_REQUEST_BYTES - total);
                if (n <= 0) break;
                total += cast(size_t) n;
                if (findHeaderEnd(buf[0 .. total]) >= 0) {
                    headersComplete = true;
                    break;
                }
            }

            if (total >= MAX_REQUEST_BYTES && !headersComplete) {
                HttpResponse err;
                err.statusCode = 431;
                err.statusText = "Request Header Fields Too Large";
                static immutable string errBody = `{"app":"hikari","status":"error","error":"headers_too_large"}`;
                sendResponse(cfd, err, cast(const(char)[]) errBody, false);
                return;
            }

            if (total == 0 || !headersComplete) return;

            auto rawReq = cast(string) buf[0 .. total];
            HttpRequest req;
            if (!parseHttpRequestInPlace(rawReq, req)) {
                HttpResponse err;
                err.statusCode = 400;
                err.statusText = "Bad Request";
                static immutable string badBody = `{"app":"hikari","status":"error","error":"malformed_request"}`;
                sendResponse(cfd, err, cast(const(char)[]) badBody, false);
                return;
            }

            if (router is null) return;

            size_t bodyLen = 0;
            auto resp = router.handleIntoBuffer(req, bodyBuf, bodyLen);
            const(char)[] bodySlice = resp.bodyText.length > 0
                ? cast(const(char)[]) resp.bodyText
                : cast(const(char)[]) bodyBuf[0 .. bodyLen];
            sendResponse(cfd, resp, bodySlice, req.method == "HEAD");

            if (dashboardResponseCompleted !is null && resp.statusCode >= 200 && resp.statusCode < 300) {
                auto path = stripConfiguredBasePath(req.path, router.config.listen.base_path);
                if (path == "/api/v1/status" || path == "/api/v1/nodes") {
                    dashboardResponseCompleted();
                }
            }
        } catch (Exception) {
            // Connection dropped or timed out cleanly
        }
    }

    private static bool sendResponse(socket_t cfd, const ref HttpResponse resp, const(char)[] bodySlice, bool headOnly) {
        char[1024] hdrBuf = void;
        size_t hdrLen = 0;
        if (formatHttpResponseHeadersInto(hdrBuf[], resp, bodySlice.length, hdrLen)) {
            if (!sendAllFd(cfd, hdrBuf[0 .. hdrLen])) return false;
            if (!headOnly && bodySlice.length > 0) {
                return sendAllFd(cfd, bodySlice);
            }
            return true;
        }
        HttpResponse fallback;
        fallback.statusCode = resp.statusCode;
        fallback.statusText = resp.statusText;
        fallback.contentType = resp.contentType;
        fallback.corsAllowOrigin = resp.corsAllowOrigin;
        fallback.retryAfter = resp.retryAfter;
        fallback.cspHeader = resp.cspHeader;
        foreach (k, v; resp.headers) fallback.headers[k] = v;
        fallback.bodyText = bodySlice.length > 0 ? bodySlice.idup : "";
        return sendAllFd(cfd, formatRawHttpResponse(fallback, headOnly));
    }

    private static void closeFdQuietly(socket_t cfd) nothrow @nogc {
        if (cfd == INVALID_FD) return;
        version (Windows) {
            closesocket(cast(SOCKET) cfd);
        } else {
            posixClose(cast(int) cfd);
        }
    }

    private static void setTimeoutMs(socket_t cfd, bool isRecv, long ms) nothrow @nogc {
        if (ms < 1) ms = 1;
        version (Windows) {
            DWORD dms = ms > DWORD.max ? DWORD.max : cast(DWORD) ms;
            setsockopt(cast(SOCKET) cfd, SOL_SOCKET, isRecv ? SO_RCVTIMEO : SO_SNDTIMEO, cast(const(char)*) &dms, DWORD.sizeof);
        } else {
            timeval tv;
            tv.tv_sec = cast(typeof(tv.tv_sec))(ms / 1000);
            tv.tv_usec = cast(typeof(tv.tv_usec))((ms % 1000) * 1000);
            setsockopt(cast(int) cfd, SOL_SOCKET, isRecv ? SO_RCVTIMEO : SO_SNDTIMEO, &tv, tv.sizeof);
        }
    }

    private static ptrdiff_t rawRecv(socket_t cfd, char* ptr, size_t len) nothrow @nogc {
        version (Windows) {
            int maxChunk = len > int.max ? int.max : cast(int) len;
            return cast(ptrdiff_t) recv(cast(SOCKET) cfd, ptr, maxChunk, 0);
        } else {
            return cast(ptrdiff_t) recv(cast(int) cfd, ptr, len, 0);
        }
    }

    private static bool sendAllFd(socket_t cfd, const(char)[] data) nothrow @nogc {
        auto deadline = MonoTime.currTime + msecs(5000);
        size_t sent = 0;
        while (sent < data.length) {
            auto remainingMs = (deadline - MonoTime.currTime).total!"msecs"();
            if (remainingMs <= 1) return false;
            setTimeoutMs(cfd, false, remainingMs);
            ptrdiff_t n;
            version (Windows) {
                size_t rem = data.length - sent;
                int chunk = rem > int.max ? int.max : cast(int) rem;
                n = cast(ptrdiff_t) send(cast(SOCKET) cfd, data.ptr + sent, chunk, 0);
            } else {
                static if (__traits(compiles, MSG_NOSIGNAL)) {
                    enum int SEND_FLAGS = MSG_NOSIGNAL;
                } else {
                    enum int SEND_FLAGS = 0;
                }
                n = cast(ptrdiff_t) send(cast(int) cfd, data.ptr + sent, data.length - sent, SEND_FLAGS);
            }
            if (n <= 0) return false;
            sent += cast(size_t) n;
        }
        return true;
    }
}
