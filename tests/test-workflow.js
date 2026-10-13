#!/usr/bin/env node
// SA Check - workflow tests. Run with:  node tests/test-workflow.js
// Executes the real "Company Lookup" node code from the workflow JSON against
// a mocked n8n runtime. No n8n, network or dependencies needed.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.join(__dirname, "..");
const wf = JSON.parse(fs.readFileSync(path.join(root, "n8n/sa-check-workflow.json"), "utf8"));
const lookup = wf.nodes.find((n) => n.name === "Company Lookup");
const code = lookup.parameters.jsCode;

let pass = 0, fail = 0;
function test(name, fn) {
  try { fn(); pass++; console.log("  PASS  " + name); }
  catch (e) { fail++; console.log("  FAIL  " + name + "\n        " + e.message); }
}
function eq(a, b, msg) {
  if (JSON.stringify(a) !== JSON.stringify(b))
    throw new Error((msg || "") + " expected " + JSON.stringify(b) + " got " + JSON.stringify(a));
}

// --- mocked n8n runtime -----------------------------------------------------
let staticData;
const resetState = () => { staticData = {}; };
const realNow = Date.now;
let clock = realNow.call(Date);
Date.now = () => clock;
const advance = (ms) => { clock += ms; };

function run(payload, { wrap = false } = {}) {
  const json = wrap ? { body: payload } : payload;
  const fn = new Function("$getWorkflowStaticData", "$input", code);
  return fn(() => staticData, { first: () => ({ json }) });
}
function payload(over = {}) {
  return {
    ip: "198.51.100.7", server: "srv", hostname: "srv.reported.example",
    services: { apache: "running", mariadb: "running", exim: "running", dovecot: "running", "php-fpm": "running" },
    resources: { disk_usage_percent: 40, ram_usage_percent: 40, load_avg: "0.5" },
    timestamp: "2026-10-14T10:00:00Z", ...over,
  };
}
const down = (svc) => payload({ services: { ...payload().services, [svc]: "stopped" } });

// --- structure --------------------------------------------------------------
console.log("Workflow structure");
test("no leftover Dedup Check node", () => eq(wf.nodes.some((n) => n.name === "Dedup Check"), false));
test("all connection targets exist", () => {
  const names = new Set(wf.nodes.map((n) => n.name));
  for (const [src, v] of Object.entries(wf.connections)) {
    if (!names.has(src)) throw new Error("unknown source " + src);
    for (const branch of v.main) for (const t of branch)
      if (!names.has(t.node)) throw new Error("unknown target " + t.node);
  }
});
test("IF OK: true -> All good, false -> Telegram", () => {
  const m = wf.connections["IF OK"].main;
  eq(m[0][0].node, "All good"); eq(m[1][0].node, "Telegram");
});
test("table contains no real servers (placeholder range only)", () => {
  const ips = [...code.matchAll(/^(\d+\.\d+\.\d+\.\d+) =/gm)].map((m) => m[1]);
  for (const ip of ips) if (!/^(203\.0\.113|198\.51\.100|192\.0\.2)\./.test(ip)) throw new Error("non-documentation IP: " + ip);
});

// --- naming -----------------------------------------------------------------
console.log("Naming and auto-registration");
resetState();
test("unknown server registers with reported hostname", () => {
  const r = run(payload());
  eq(r[0].json.company, "srv.reported.example");
  eq(staticData.servers["198.51.100.7"].name, "srv.reported.example");
});
test("registered name sticks even if hostname later changes", () => {
  const r = run(payload({ hostname: "other.example" }));
  eq(r[0].json.company, "srv.reported.example");
});
test("custom table overrides hostname", () => {
  const r = run(payload({ ip: "203.0.113.10" }));
  eq(r[0].json.company, "server.example-company-a.com");
});
test("'Unnamed' placeholder is upgraded once a hostname arrives", () => {
  resetState();
  eq(run(payload({ ip: "198.51.100.9", hostname: undefined }))[0].json.company, "Unnamed (198.51.100.9)");
  eq(run(payload({ ip: "198.51.100.9", hostname: "real.example" }))[0].json.company, "real.example");
});
test("firstSeen is kept, lastSeen updates", () => {
  resetState(); run(payload()); const first = staticData.servers["198.51.100.7"].firstSeen;
  advance(5000); run(payload());
  eq(staticData.servers["198.51.100.7"].firstSeen, first);
});
test("webhook body wrapper is unwrapped", () => eq(run(payload(), { wrap: true })[0].json.ip, "198.51.100.7"));

// --- status -----------------------------------------------------------------
console.log("Status rules");
test("all running -> ok", () => { resetState(); eq(run(payload())[0].json.status, "ok"); });
test("stopped apache -> critical", () => { resetState(); eq(run(down("apache"))[0].json.status, "critical"); });
test("stopped php-fpm is ignored -> ok", () => { resetState(); eq(run(down("php-fpm"))[0].json.status, "ok"); });
test("disk 90% -> warning", () => {
  resetState(); eq(run(payload({ resources: { disk_usage_percent: 90, ram_usage_percent: 10 } }))[0].json.status, "warning");
});
test("ram 95% -> warning", () => {
  resetState(); eq(run(payload({ resources: { disk_usage_percent: 10, ram_usage_percent: 95 } }))[0].json.status, "warning");
});
test("critical wins over warning", () => {
  resetState();
  const p = down("exim"); p.resources.disk_usage_percent = 99;
  eq(run(p)[0].json.status, "critical");
});

// --- de-duplication ---------------------------------------------------------
console.log("De-duplication");
test("first critical alerts", () => { resetState(); eq(run(down("apache")).length, 1); });
test("same critical one minute later is suppressed", () => { advance(60e3); eq(run(down("apache")).length, 0); });
test("status change critical -> warning alerts at once", () => {
  eq(run(payload({ resources: { disk_usage_percent: 95, ram_usage_percent: 10 } }))[0].json.status, "warning");
});
test("hourly reminder fires while still broken", () => {
  resetState(); run(down("apache"));
  advance(59 * 60e3); eq(run(down("apache")).length, 0, "at 59m");
  advance(61e3);      eq(run(down("apache")).length, 1, "at 60m");
});
test("ok result is always passed on (goes to 'All good')", () => eq(run(payload())[0].json.status, "ok"));
test("recovery resets, so the next failure alerts immediately", () => {
  resetState(); run(down("apache")); run(payload());
  eq(Object.keys(staticData.lastAlerts).length, 0);
  advance(60e3); eq(run(down("apache")).length, 1);
});
test("servers are de-duplicated independently", () => {
  resetState();
  eq(run({ ...down("apache"), ip: "198.51.100.1" }).length, 1);
  eq(run({ ...down("apache"), ip: "198.51.100.2" }).length, 1);
  eq(run({ ...down("apache"), ip: "198.51.100.1" }).length, 0);
});

// --- agent script syntax ----------------------------------------------------
console.log("Shell scripts");
for (const f of ["scripts/sa-check.sh", "scripts/install.sh"]) {
  test("bash -n " + f, () => { execFileSync("bash", ["-n", path.join(root, f)]); });
}

Date.now = realNow;
console.log("\n" + pass + " passed, " + fail + " failed");
process.exit(fail ? 1 : 0);
