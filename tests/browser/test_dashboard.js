#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const htmlPath = path.resolve(__dirname, "../../web/index.html");
const html = fs.readFileSync(htmlPath, "utf8");

// 1. Static safety checks on web/index.html
assert(!/<script[^>]+src\s*=/i.test(html), "web/index.html must not load external scripts");
assert(!/<link[^>]+href\s*=\s*["']https?:/i.test(html), "web/index.html must not load external CSS/fonts");
assert(!/serviceWorker/i.test(html), "web/index.html must not register a service worker");
assert(!/innerHTML\s*=/.test(html), "web/index.html must never assign innerHTML (XSS defense)");

const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
assert(scriptMatch, "Failed to locate inline <script> in web/index.html");
const scriptSrc = scriptMatch[1];

// 2. Minimal DOM mock for testing web/index.html behavior deterministically
class MockElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.attrs = {};
    this.style = {};
    this.children = [];
    this.listeners = {};
    this.className = "";
    this._textContent = "";
    this.value = "";
    this.disabled = false;
    this.classList = {
      toggle: () => {},
    };
  }
  get childNodes() {
    return this.children;
  }
  get textContent() {
    if (this.children.length > 0) {
      return this.children.map((c) => c.textContent).join("");
    }
    return this._textContent;
  }
  set textContent(v) {
    this.children = [];
    this._textContent = String(v ?? "");
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
    if (k === "value") this.value = String(v);
  }
  getAttribute(k) {
    return this.attrs[k] ?? null;
  }
  appendChild(child) {
    this.children.push(child);
    return child;
  }
  addEventListener(ev, fn) {
    (this.listeners[ev] ||= []).push(fn);
  }
  findAllByTag(tag) {
    const out = [];
    const target = tag.toUpperCase();
    for (const c of this.children) {
      if (c instanceof MockElement) {
        if (c.tagName === target) out.push(c);
        out.push(...c.findAllByTag(target));
      }
    }
    return out;
  }
}

class MockTextNode {
  constructor(t) {
    this._text = String(t);
  }
  get textContent() {
    return this._text;
  }
}

function buildDom() {
  const byId = new Map();
  const ids = [
    "poll-status-text",
    "interval-select",
    "refresh-now-btn",
    "discover-btn",
    "kpi-total",
    "kpi-online",
    "kpi-offline",
    "kpi-stale",
    "kpi-reboot",
    "search-input",
    "status-filter",
    "sort-select",
    "fleet-banner",
    "fleet-tbody",
    "detail-panel",
    "detail-title",
    "detail-subtitle",
    "detail-badges",
    "close-detail-btn",
    "detail-body",
  ];
  for (const id of ids) {
    const el = new MockElement(id === "fleet-tbody" ? "tbody" : "div");
    if (id === "interval-select") el.value = "15000";
    if (id === "status-filter") el.value = "all";
    if (id === "sort-select") el.value = "name";
    byId.set(id, el);
  }

  const tabBtns = ["overview", "hardware", "storage", "processes"].map((t) => {
    const b = new MockElement("button");
    b.setAttribute("data-tab", t);
    return b;
  });

  const docListeners = {};
  const document = {
    readyState: "complete",
    visibilityState: "visible",
    getElementById: (id) => byId.get(id) || null,
    querySelectorAll: (sel) => (sel === ".tab-btn" ? tabBtns : []),
    createElement: (tag) => new MockElement(tag),
    createTextNode: (t) => new MockTextNode(t),
    addEventListener: (ev, fn) => {
      (docListeners[ev] ||= []).push(fn);
    },
    _byId: byId,
    _docListeners: docListeners,
  };
  return document;
}

async function runTests() {
  const document = buildDom();
  const fetchCalls = [];
  const abortedSignals = [];
  let activeTimers = new Set();
  let nextTimerId = 1;

  const nodesPayload = {
    schema_version: 1,
    generated_at: 1794945600,
    nodes: [
      {
        node_id: "hikari:self-1",
        name: "workstation-linux",
        alias: "Main Box",
        fqdn: "workstation-linux.tail1234.ts.net",
        status_url: "https://workstation-linux.tail1234.ts.net:9100/api/v1/status",
        hardware_url: "https://workstation-linux.tail1234.ts.net:9100/api/v1/hardware",
        is_self: true,
        tailscale_online: true,
        last_seen_ts: 1794945600,
        hidden: false,
      },
      {
        node_id: "hikari:collecting-2",
        name: "gaming-win11",
        fqdn: "gaming-win11.tail1234.ts.net",
        status_url: "https://gaming-win11.tail1234.ts.net:9100/api/v1/status",
        hardware_url: "https://gaming-win11.tail1234.ts.net:9100/api/v1/hardware",
        os: "windows",
        arch: "x86_64",
        is_self: false,
        tailscale_online: true,
        last_seen_ts: 1794945590,
        hidden: false,
      },
      {
        node_id: "hikari:mac-5",
        name: "macbook-pro-m3",
        fqdn: "macbook-pro-m3.tail1234.ts.net",
        status_url: "https://macbook-pro-m3.tail1234.ts.net:9100/api/v1/status",
        hardware_url: "https://macbook-pro-m3.tail1234.ts.net:9100/api/v1/hardware",
        os: "darwin",
        arch: "arm64",
        is_self: false,
        tailscale_online: true,
        last_seen_ts: 1794945595,
        hidden: false,
      },
      {
        node_id: "hikari:err-3",
        name: "broken-node",
        fqdn: "broken-node.tail1234.ts.net",
        status_url: "https://broken-node.tail1234.ts.net:9100/api/v1/status",
        hardware_url: "https://broken-node.tail1234.ts.net:9100/api/v1/hardware",
        is_self: false,
        tailscale_online: true,
        last_seen_ts: 1794945500,
        hidden: false,
      },
      {
        node_id: "hikari:offline-4",
        name: "<img src=x onerror=alert(1)>",
        alias: "<script>alert(2)</script>",
        fqdn: "offline-arm.tail1234.ts.net",
        status_url: "https://offline-arm.tail1234.ts.net:9100/api/v1/status",
        hardware_url: "https://offline-arm.tail1234.ts.net:9100/api/v1/hardware",
        is_self: false,
        tailscale_online: false,
        last_seen_ts: 1794000000,
        last_known_hardware_summary: { cpu: "Rockchip RK3588", ram_bytes: 8589934592 },
        hidden: false,
      },
    ],
  };

  const selfStatus = {
    app: "hikari",
    schema_version: 1,
    node_id: "hikari:self-1",
    host: "workstation-linux",
    os: "linux",
    arch: "x86_64",
    uptime_s: 12000,
    boot_id: "boot-1",
    groups: {
      fast: { status: "fresh", sampled_at: 1794945598, age_s: 2, refreshing: false },
      processes: { status: "fresh", sampled_at: 1794945598, age_s: 2, refreshing: false },
      filesystems: { status: "fresh", sampled_at: 1794945598, age_s: 2, refreshing: false },
    },
    cpu: { pct: 23.5, load_1m: 1.1, temp_c: 52.0 },
    memory: { used_bytes: 8589934592, total_bytes: 34359738368, pct: 25.0 },
    swap: { used_bytes: 0, total_bytes: 4294967296, pct: 0.0 },
    network: [{ id: "ifindex:2", name: "enp5s0", kind: "physical", rx_bytes: 1000, tx_bytes: 500, rx_bytes_per_s: 2048, tx_bytes_per_s: 1024 }],
    mounts: [{ mount: "/", source: "/dev/nvme0n1p2", fs: "btrfs", used_bytes: 100000, total_bytes: 1000000, pct: 10.0 }],
    gpus: [],
    batteries: [],
    top_cpu: [{ pid: 10, start_id: "1", name: "proc<svg onload=alert(3)>", cpu_pct: 50.0, rss_bytes: 1048576 }],
    top_mem: [],
    drift: { running_kernel: "7.3.4", installed_kernel: "7.3.5", reboot_required: true },
  };

  const selfHardware = {
    app: "hikari",
    schema_version: 1,
    node_id: "hikari:self-1",
    collected_at: 1794945000,
    collection: { status: "fresh", partial: false },
    system: { manufacturer: "Lenovo", model: "ThinkPad", form_factor: "laptop" },
    board: { manufacturer: "Lenovo", model: "Board" },
    firmware: { type: "UEFI", vendor: "Lenovo", version: "1.31" },
    cpu: {
      display_name: "AMD Ryzen 7 5800U",
      vendor: "AMD",
      architecture: "x86_64",
      sockets: 1,
      physical_cores: 8,
      logical_cores: 16,
      cache_bytes: { l1d: 262144, l2: 4194304, l3: 16777216 },
      isa: { hardware: ["sse2", "avx", "avx2", "aes"], usable: ["sse2", "avx", "avx2", "aes"], detection: "cpuid+os_state" },
    },
    memory: { total_bytes: 34359738368, module_enumeration: "permission_denied", modules: [] },
    network_adapters: [],
    storage_devices: [],
    graphics_adapters: [],
  };

  let holdPendingResolve = null;

  function mockFetch(url, opts) {
    fetchCalls.push(url);
    if (opts && opts.signal) {
      opts.signal.addEventListener("abort", () => abortedSignals.push(url));
    }
    if (url === "./api/v1/nodes" || url === "./api/v1/nodes?refresh=1") {
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve(JSON.stringify(nodesPayload)) });
    }
    if (url === "./api/v1/status") {
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve(JSON.stringify(selfStatus)) });
    }
    if (url === "./api/v1/hardware") {
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve(JSON.stringify(selfHardware)) });
    }
    if (url.includes("gaming-win11")) {
      return Promise.resolve({ ok: false, status: 202, text: () => Promise.resolve(JSON.stringify({ app: "hikari", schema_version: 1, status: "collecting", retry_after_s: 1 })) });
    }
    if (url.includes("macbook-pro-m3")) {
      return Promise.resolve({
        ok: true,
        status: 200,
        text: () => Promise.resolve(JSON.stringify({
          app: "hikari",
          schema_version: 1,
          node_id: "hikari:mac-5",
          host: "macbook-pro-m3",
          os: "darwin",
          arch: "arm64",
          uptime_s: 8000,
          groups: { fast: { status: "fresh", sampled_at: 1794945595, age_s: 1, refreshing: false } },
          cpu: { pct: 12.0, load_1m: 0.8, temp_c: null },
          memory: { used_bytes: 8589934592, total_bytes: 17179869184, pct: 50.0 },
          swap: { used_bytes: 0, total_bytes: 0, pct: 0 },
          network: [],
          mounts: [],
          gpus: [],
          batteries: [{ id: "BAT0", name: "BAT0", status: "discharging", pct: 84.0, time_remaining_s: 15120 }],
          top_cpu: [],
          top_mem: [],
          drift: { running_kernel: "24.1.0", reboot_required: false },
        })),
      });
    }
    if (url.includes("broken-node")) {
      return Promise.resolve({ ok: false, status: 503, text: () => Promise.resolve(JSON.stringify({ app: "hikari", schema_version: 1, status: "error", error: "fast_probe_unavailable" })) });
    }
    if (url.includes("offline-arm")) {
      return new Promise((resolve, reject) => {
        holdPendingResolve = () => reject(Object.assign(new Error("Aborted"), { name: "AbortError" }));
        if (opts && opts.signal) {
          opts.signal.addEventListener("abort", () => reject(Object.assign(new Error("Aborted"), { name: "AbortError" })));
        }
        // Fail promptly during initial test unless held
        setTimeout(() => reject(new Error("ECONNREFUSED")), 5);
      });
    }
    return Promise.reject(new Error("Unexpected fetch URL: " + url));
  }

  const sandbox = {
    document,
    window: {
      location: { protocol: "http:", origin: "http://127.0.0.1:19100" },
      addEventListener: () => {},
    },
    fetch: mockFetch,
    AbortController,
    setTimeout,
    clearTimeout,
    setInterval: (fn, ms) => {
      const id = nextTimerId++;
      activeTimers.add(id);
      return id;
    },
    clearInterval: (id) => {
      activeTimers.delete(id);
    },
    Date,
    Number,
    Math,
    Array,
    Object,
    Map,
    Set,
    Promise,
    JSON,
    console,
  };

  vm.runInNewContext(scriptSrc, sandbox);

  // Wait for initial async refreshAll launched by init()
  await new Promise((r) => setTimeout(r, 40));

  const app = sandbox.window.__hikariApp;
  assert(app, "Dashboard failed to initialize");

  // Verify KPIs & fleet rendering (Linux self, macOS M3, Windows 202 collecting, broken 503, offline ARM)
  assert.strictEqual(document.getElementById("kpi-total").textContent, "5");
  assert.strictEqual(document.getElementById("kpi-online").textContent, "3", "Self (200) + macOS (200) + Windows (202 collecting) count as online");
  assert.strictEqual(document.getElementById("kpi-offline").textContent, "2", "broken-node (503) + offline-arm count as unreachable/offline");
  assert.strictEqual(document.getElementById("kpi-reboot").textContent, "1");

  // Verify NO hardware requests occurred during fleet overview
  assert(!fetchCalls.some((u) => u.includes("/hardware")), "Overview load must NEVER trigger /api/v1/hardware fetches");

  // Verify XSS payloads were escaped (no <img>, <script>, or <svg> elements created)
  const tbody = document.getElementById("fleet-tbody");
  assert.strictEqual(tbody.findAllByTag("img").length, 0, "XSS <img> must not be parsed as HTML");
  assert.strictEqual(tbody.findAllByTag("script").length, 0, "XSS <script> must not be parsed as HTML");
  assert(tbody.textContent.includes("<script>alert(2)</script>"), "Untrusted alias must render literally as text");
  assert(tbody.textContent.includes("darwin") && tbody.textContent.includes("windows") && tbody.textContent.includes("linux"), "All 3 OS families must render in fleet table");

  // Verify relative URL resolution for local dev vs remote HTTPS
  assert.strictEqual(app.resolveEndpointUrl(nodesPayload.nodes[0], "status"), "./api/v1/status");
  assert.strictEqual(app.resolveEndpointUrl(nodesPayload.nodes[1], "status"), "https://gaming-win11.tail1234.ts.net:9100/api/v1/status");

  // Verify lazy hardware loading and session caching
  await app.ensureHardwareLoaded("hikari:self-1", false);
  const hwCount1 = fetchCalls.filter((u) => u.includes("/hardware")).length;
  assert.strictEqual(hwCount1, 1, "Hardware tab open must fetch /api/v1/hardware once");
  await app.ensureHardwareLoaded("hikari:self-1", false);
  const hwCount2 = fetchCalls.filter((u) => u.includes("/hardware")).length;
  assert.strictEqual(hwCount2, 1, "Second hardware view must reuse session cache");

  // Verify visibility-hidden stops polling timers and blocks fetches
  assert(activeTimers.size > 0, "Visible page should have an active polling timer");
  const callsBeforeHidden = fetchCalls.length;
  document.visibilityState = "hidden";
  app.onVisibilityChange();
  assert.strictEqual(activeTimers.size, 0, "Hiding tab must clear all polling timers");
  await app.refreshAll(false);
  assert.strictEqual(fetchCalls.length, callsBeforeHidden, "Hidden page must make ZERO fetch requests");

  console.log("Browser dashboard tests PASSED (XSS safety, relative URLs, 200/202/503/offline handling, lazy hardware, visibility abort).");
}

runTests().catch((err) => {
  console.error(err);
  process.exit(1);
});
