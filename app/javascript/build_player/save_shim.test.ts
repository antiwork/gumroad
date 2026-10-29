import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";

import { cast } from "$app/utils/cast";

const SHIM = readFileSync(resolve(__dirname, "save_shim.js"), "utf8");
const CARRIED_PREFIX = "gumroad-build-save:";

type Batch = { clear: boolean; remove: string[]; set: Record<string, string>; writer: string; sequence: number };
type Reply = { ok: boolean; status: number } | "network-error" | "never";

// Runs the shim as PlayerDocument injects it, with a fake frame: fetch answers from `replies` (204 by
// default), sendBeacon records what it was given, and timers run only when `tick` is called.
const runShim = ({
  save = {},
  windowName = "",
  replies = [],
}: { save?: Record<string, string>; windowName?: string; replies?: Reply[] } = {}) => {
  const listeners: Record<string, () => void> = {};
  const timers: (() => void)[] = [];
  const sent: Batch[] = [];
  const beacons: Batch[] = [];
  const alerts: unknown[] = [];
  const frameWindow: Record<string, unknown> = {
    name: windowName,
    parent: { postMessage: (message: unknown) => alerts.push(message) },
    addEventListener: (type: string, listener: () => void) => (listeners[type] = listener),
  };
  Object.defineProperty(frameWindow, "localStorage", {
    configurable: true,
    get: () => {
      throw new Error("SecurityError");
    },
  });
  const frameDocument = {
    visibilityState: "visible",
    addEventListener: (type: string, listener: () => void) => (listeners[type] = listener),
  };
  const config = {
    save,
    saveUrl: "/save",
    flushDelayMs: 1000,
    beaconMaxBytes: 60000,
    failedMessageType: "gumroad:build-save-failed",
    failuresBeforeAlert: 3,
    carriedPrefix: CARRIED_PREFIX,
    maxWriterIdLength: 32,
  };
  const parse = (body: string): Batch => cast<Batch>(JSON.parse(body));
  runInNewContext(SHIM.replace("JSON.parse(__CONFIG__)", `JSON.parse(${JSON.stringify(JSON.stringify(config))})`), {
    window: frameWindow,
    document: frameDocument,
    navigator: {
      sendBeacon: (_url: string, body: string) => {
        beacons.push(parse(body));
        return true;
      },
    },
    fetch: (_url: string, init: { body: string }) => {
      sent.push(parse(init.body));
      const reply = replies.shift() ?? { ok: true, status: 204 };
      if (reply === "network-error") return Promise.reject(new Error("offline"));
      if (reply === "never") return new Promise(() => undefined);
      return Promise.resolve(reply);
    },
    setTimeout: (callback: () => void) => timers.push(callback),
    clearTimeout: () => undefined,
    JSON,
    Object,
    Array,
    Math,
    Date,
    String,
    Blob,
    Proxy,
    Error,
    Promise,
  });
  const storage = cast<Storage>(frameWindow.localStorage);
  const tick = async () => {
    timers.shift()?.();
    for (let i = 0; i < 3; i += 1) await Promise.resolve();
  };
  const hide = () => {
    frameDocument.visibilityState = "hidden";
    listeners.visibilitychange?.();
  };
  return { storage, sent, beacons, alerts, tick, hide, leave: () => listeners.pagehide?.(), frameWindow };
};

describe("save shim", () => {
  it("restores the purchase's save into localStorage", () => {
    // Parsed, because an object literal would treat "__proto__" as the prototype, not a key.
    const save = cast<Record<string, string>>(JSON.parse('{"level":"3","__proto__":"kept"}'));
    const { storage } = runShim({ save });

    expect(storage.getItem("level")).toBe("3");
    expect(storage.getItem("__proto__")).toBe("kept");
  });

  it("sends writes in one numbered batch per delay", async () => {
    const { storage, sent, tick } = runShim();
    storage.setItem("level", "4");
    storage.best = "10";
    storage.removeItem("level");

    await tick();

    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ clear: false, remove: ["level"], set: { best: "10" }, sequence: 1 });
  });

  it("sends a batch that failed again, in front of newer changes and with a higher number", async () => {
    const { storage, sent, tick } = runShim({ replies: ["network-error"] });
    storage.setItem("a", "1");
    await tick();
    storage.setItem("b", "2");
    await tick();

    expect(sent[1]).toMatchObject({ set: { a: "1", b: "2" }, writer: sent[0]?.writer });
    expect(sent[1]?.sequence).toBeGreaterThan(sent[0]?.sequence ?? Infinity);
  });

  it("waits for the batch in flight before it sends the next one", async () => {
    const { storage, sent, tick } = runShim({ replies: ["never"] });
    storage.setItem("a", "1");
    await tick();
    storage.setItem("b", "2");
    await tick();

    expect(sent).toHaveLength(1);
  });

  it("tells the page after three failures, and at once for a batch the server rejects", async () => {
    const offline = runShim({ replies: ["network-error", "network-error", "network-error"] });
    offline.storage.setItem("a", "1");
    await offline.tick();
    await offline.tick();
    expect(offline.alerts).toHaveLength(0);
    await offline.tick();
    expect(offline.alerts).toEqual([{ type: "gumroad:build-save-failed" }]);

    const rejected = runShim({ replies: [{ ok: false, status: 422 }] });
    rejected.storage.setItem("a", "1");
    await rejected.tick();
    expect(rejected.alerts).toHaveLength(1);
  });

  it("on leaving, sends everything unconfirmed, including the batch in flight, in one beacon", async () => {
    const { storage, beacons, tick, leave } = runShim({ replies: ["never"] });
    storage.setItem("a", "1");
    await tick();
    storage.setItem("b", "2");

    leave();

    expect(beacons).toHaveLength(1);
    expect(beacons[0]?.set).toEqual({ a: "1", b: "2" });
  });

  it("on hiding, sends a beacon and keeps the changes queued in case it did not get through", async () => {
    const { storage, sent, beacons, tick, hide } = runShim();
    storage.setItem("a", "1");

    hide();
    expect(beacons[0]?.set).toEqual({ a: "1" });

    await tick();
    expect(sent.at(-1)?.set).toEqual({ a: "1" });
    expect(sent.at(-1)?.sequence).toBeGreaterThan(beacons[0]?.sequence ?? Infinity);
  });

  it("on closing after a hide, sends only what changed since the hide beacon, so both fit the quota", () => {
    const closing = runShim();
    closing.storage.setItem("a", "1");
    closing.hide();
    closing.leave();
    expect(closing.beacons).toHaveLength(1);

    const writesWhileHidden = runShim();
    writesWhileHidden.storage.setItem("a", "1");
    writesWhileHidden.hide();
    writesWhileHidden.storage.setItem("b", "2");
    writesWhileHidden.leave();
    expect(writesWhileHidden.beacons.map((b) => b.set)).toEqual([{ a: "1" }, { b: "2" }]);
    expect(writesWhileHidden.beacons[1]?.sequence).toBeGreaterThan(writesWhileHidden.beacons[0]?.sequence ?? Infinity);
  });

  it("hands every change made on the page to the next page, which applies it and keeps numbering", async () => {
    const first = runShim();
    first.storage.setItem("level", "4");
    await first.tick();
    first.storage.setItem("coins", "10");
    first.leave();

    const next = runShim({ save: { level: "3" }, windowName: String(first.frameWindow.name) });
    expect(next.storage.getItem("level")).toBe("4");
    expect(next.storage.getItem("coins")).toBe("10");
    expect(next.frameWindow.name).toBe("");

    await next.tick();
    expect(next.sent[0]).toMatchObject({ set: { level: "4", coins: "10" }, writer: first.beacons[0]?.writer });
    expect(next.sent[0]?.sequence).toBeGreaterThan(first.beacons[0]?.sequence ?? Infinity);
  });
});
