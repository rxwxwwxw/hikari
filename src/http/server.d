module http.server;

import core.config : isLoopbackBindAddress;
import core.atomic;
import core.thread;
import http.routes;
import http.security;
import std.algorithm : startsWith;
import std.conv : to;
import std.format : format;
import std.socket;
import std.string : indexOf, split, strip, toLower;

HttpRequest parseRawHttpRequest(string raw) {
    HttpRequest req;
    auto headerEnd = raw.indexOf("\r\n\r\n");
    if (headerEnd < 0) headerEnd = raw.indexOf("\n\n");
    auto head = headerEnd >= 0 ? raw[0 .. headerEnd] : raw;

    auto lines = head.split('\n');
    if (lines.length == 0) throw new Exception("Empty request");

    auto reqLine = lines[0].strip();
    auto parts = reqLine.split(' ');
    if (parts.length < 2) throw new Exception("Malformed request line");
    req.method = parts[0].strip();
    auto target = parts[1].strip();
    if (target.length > MAX_URI_LENGTH) throw new Exception("URI too long");

    auto qIdx = target.indexOf('?');
    if (qIdx >= 0) {
        req.path = target[0 .. qIdx];
        req.query = target[qIdx + 1 .. $];
    } else {
        req.path = target;
    }

    foreach (line; lines[1 .. $]) {
        auto clean = line.strip();
        if (clean.length == 0) continue;
        auto colon = clean.indexOf(':');
        if (colon <= 0) continue;
        auto k = clean[0 .. colon].strip().toLower();
        auto v = clean[colon + 1 .. $].strip();
        req.headers[k] = v;
    }
    return req;
}

string formatRawHttpResponse(const ref HttpResponse resp, bool headOnly = false) {
    import std.array : appender;
    auto app = appender!string();
    app.put(format!"HTTP/1.1 %d %s\r\n"(resp.statusCode, resp.statusText));
    app.put(format!"Content-Type: %s\r\n"(resp.contentType));
    app.put(format!"Content-Length: %u\r\n"(resp.bodyText.length));
    app.put("Connection: close\r\n");
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

    private TcpSocket listener;
    private shared bool running = false;
    private shared size_t rawHandle = size_t.max;
    private ushort boundPort = 0;
    private shared uint clients = 0;
    private uint maxClients;

    uint activeClients() { return atomicLoad(clients); }

    this(string bindAddr, ushort port, HikariRouter router, uint maxClients = 32) {
        if (!maxClients || maxClients > 1024) throw new Exception("Invalid HTTP client limit");
        this.maxClients = maxClients;
        if (!isLoopbackBindAddress(bindAddr)) {
            throw new Exception("Security violation: HTTP server refuses non-loopback bind address: " ~ bindAddr);
        }
        this.bindAddr = bindAddr == "localhost" ? "127.0.0.1" : bindAddr;
        this.port = port;
        this.router = router;
    }

    ushort actualPort() const nothrow @safe {
        return boundPort;
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
            import core.sys.windows.winsock2 : SO_EXCLUSIVEADDRUSE, SOL_SOCKET, setsockopt;
            int one = 1;
            if (setsockopt(listener.handle, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, &one, int.sizeof) != 0) {
                throw new Exception("Unable to set SO_EXCLUSIVEADDRUSE on loopback listener");
            }
        } else {
            listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        }
        listener.bind(addr);
        listener.listen(64);
        boundPort = to!ushort(listener.localAddress().toPortString());
        atomicStore(rawHandle, cast(size_t) listener.handle);
        atomicStore(running, true);
    }

    /// Async-signal/console-handler safe stop: no GC, no exceptions. Closing the raw
    /// listening socket unblocks accept() so serveLoop() returns.
    void requestStop() nothrow @nogc {
        atomicStore(running, false);
        auto h = atomicExchange(&rawHandle, size_t.max);
        if (h == size_t.max) return;
        version (Windows) {
            import core.sys.windows.winsock2 : closesocket, SOCKET;
            closesocket(cast(SOCKET) h);
        } else {
            import core.sys.posix.sys.socket : shutdown, SHUT_RDWR;
            shutdown(cast(int) h, SHUT_RDWR);
        }
    }

    private void spawnClientHandler(Socket c) {
        // Only the accept loop admits clients. Reject overload before allocating
        // a thread; closing here never blocks accept on a slow client's writes.
        if (atomicLoad(clients) >= maxClients) { closeQuietly(c); return; }
        atomicOp!"+="(clients, 1);
        try {
            auto t = new Thread({
                scope (exit) atomicOp!"-="(clients, 1);
                handleConnection(c);
            });
            t.isDaemon = true;
            t.start();
        } catch (Exception) {
            atomicOp!"-="(clients, 1);
            closeQuietly(c);
        }
    }

    void serveLoop() {
        if (listener is null) startListening();
        while (atomicLoad(running)) {
            try {
                listener.blocking = true;
                auto client = listener.accept();
                spawnClientHandler(client);
            } catch (SocketException) {
                if (!atomicLoad(running)) break;
            } catch (Exception) {
                if (!atomicLoad(running)) break;
            }
        }
    }

    // Called after stopping acceptance. An external update supervisor waits for
    // the service to stop before starting the replacement, preserving responses.
    void drainClients() {
        import core.time : msecs;
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
    }

    private void handleConnection(Socket client) {
        scope (exit) {
            closeQuietly(client);
        }
        try {
            import core.time : msecs;
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, msecs(3000));
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, msecs(5000));

            char[MAX_REQUEST_BYTES + 1] buf;
            size_t total = 0;
            bool headersComplete = false;

            import core.time : MonoTime;
            auto headerDeadline = MonoTime.currTime + msecs(3000);
            while (total < MAX_REQUEST_BYTES) {
                auto remaining = headerDeadline - MonoTime.currTime;
                if (remaining <= msecs(1)) return;
                client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, remaining);
                auto n = client.receive(buf[total .. MAX_REQUEST_BYTES]);
                if (n <= 0) break;
                total += n;
                auto slice = cast(string) buf[0 .. total];
                if (slice.indexOf("\r\n\r\n") >= 0 || slice.indexOf("\n\n") >= 0) {
                    headersComplete = true;
                    break;
                }
            }

            if (total >= MAX_REQUEST_BYTES && !headersComplete) {
                HttpResponse err;
                err.statusCode = 431;
                err.statusText = "Request Header Fields Too Large";
                err.bodyText = `{"app":"hikari","status":"error","error":"headers_too_large"}`;
                sendAll(client, formatRawHttpResponse(err));
                return;
            }

            if (total == 0 || !headersComplete) return;

            auto rawReq = cast(string) buf[0 .. total];
            HttpRequest req;
            try {
                req = parseRawHttpRequest(rawReq);
            } catch (Exception e) {
                HttpResponse err;
                err.statusCode = 400;
                err.statusText = "Bad Request";
                err.bodyText = `{"app":"hikari","status":"error","error":"malformed_request"}`;
                sendAll(client, formatRawHttpResponse(err));
                return;
            }

            auto resp = router.handle(req);
            auto wire = formatRawHttpResponse(resp, req.method == "HEAD");
            sendAll(client, wire);
            auto path = stripConfiguredBasePath(req.path, router.config.listen.base_path);
            if (dashboardResponseCompleted !is null && resp.statusCode >= 200 && resp.statusCode < 300 &&
                (path == "/api/v1/status" || path == "/api/v1/nodes")) dashboardResponseCompleted();
        } catch (Exception) {
            // Connection dropped or timed out cleanly
        }
    }

    private static void closeQuietly(Socket sock) nothrow {
        try { sock.close(); } catch (Exception) {}
    }

    private static void sendAll(Socket sock, string data) {
        import core.time : MonoTime, msecs;
        auto deadline = MonoTime.currTime + msecs(5000);
        size_t sent = 0;
        auto bytes = cast(const(ubyte)[]) data;
        while (sent < bytes.length) {
            auto remaining = deadline - MonoTime.currTime;
            if (remaining <= msecs(1)) throw new Exception("Response deadline exceeded");
            sock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, remaining);
            auto n = sock.send(bytes[sent .. $]);
            if (n <= 0) throw new Exception("Response connection closed");
            sent += n;
        }
    }
}
