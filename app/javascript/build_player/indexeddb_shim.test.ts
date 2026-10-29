import { beforeEach, describe, expect, it, vi } from "vitest";

import { cast } from "$app/utils/cast";

import { done } from "./indexeddb_shim";

// persist patches the library's IDBDatabase prototype, so each test gets fresh copies of both modules.
const load = async () => {
  vi.resetModules();
  return { shim: await import("./indexeddb_shim"), fake: await import("fake-indexeddb") };
};
type Loaded = Awaited<ReturnType<typeof load>>;

const committed = (transaction: IDBTransaction) =>
  new Promise<void>((resolve) => {
    transaction.oncomplete = () => resolve();
  });

// A Godot-like file store with in-line keys and an index, plus an out-of-line counter store.
const seed = async (factory: IDBFactory) => {
  const request = factory.open("/userfs", 21);
  request.onupgradeneeded = () => {
    const files = request.result.createObjectStore("FILE_DATA", { keyPath: "path" });
    files.createIndex("timestamp", "timestamp");
    request.result.createObjectStore("counters", { autoIncrement: true });
  };
  const db = await done(request);
  const transaction = db.transaction(["FILE_DATA", "counters"], "readwrite");
  transaction.objectStore("FILE_DATA").put({
    path: "/userfs/save.dat",
    timestamp: new Date(1_700_000_000_000),
    mode: 33206,
    contents: new Int8Array([1, -2, 3]),
  });
  transaction.objectStore("counters").put("first");
  await committed(transaction);
  db.close();
};

const slot = (initial: string | null = null) => {
  const values: (string | null)[] = [];
  const failures: true[] = [];
  let value = initial;
  return {
    values,
    failures,
    get: () => value,
    set: (next: string | null) => {
      value = next;
      values.push(next);
    },
    fail: () => failures.push(true),
  };
};

// A snapshot of a factory with no write in flight, as the save holds it.
const saved = (snapshot: unknown) =>
  cast<NonNullable<ReturnType<Loaded["shim"]["takeSnapshot"]>>>(JSON.parse(JSON.stringify(snapshot)));

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

let loaded: Loaded;
beforeEach(async () => {
  loaded = await load();
});

describe("indexeddb shim", () => {
  it("encodes values so they come back as the same types", () => {
    const { encode, decode } = loaded.shim;
    const object = cast<Record<string, unknown>>(JSON.parse('{"__proto__":"kept"}'));
    const value = {
      bytes: new Uint8Array([0, 255]),
      floats: new Float32Array([1.5]),
      buffer: new Uint8Array([7]).buffer,
      when: new Date(5),
      invalidDate: new Date(NaN),
      view: new Uint8Array(new Uint8Array([9, 1, 2, 8]).buffer, 1, 2),
      dataView: new DataView(new ArrayBuffer(8), 2, 4),
      numbers: [NaN, -0, Infinity, 1],
      map: new Map([["a", new Set([1])]]),
      nothing: undefined,
      big: 2n ** 64n,
      looksLikeATag: { b: "AA==", t: "Uint8Array" },
      object,
    };

    const back = decode(cast(JSON.parse(JSON.stringify(encode(value)))));

    expect(back).toEqual(value);
    expect(Object.getPrototypeOf(cast<{ object: object }>(back).object)).toBe(Object.prototype);
    expect(cast<{ bytes: unknown }>(back).bytes).toBeInstanceOf(Uint8Array);
    const view = cast<{ view: Uint8Array }>(back).view;
    expect([view.byteOffset, view.length, [...new Uint8Array(view.buffer)]]).toEqual([1, 2, [9, 1, 2, 8]]);
    expect(Number.isNaN(cast<{ invalidDate: Date }>(back).invalidDate.getTime())).toBe(true);
    expect(cast<{ buffer: unknown }>(back).buffer).toBeInstanceOf(ArrayBuffer);
  });

  it("refuses values it could not bring back exactly", () => {
    const { encode } = loaded.shim;
    const shared = { level: 1 };
    const cycle: Record<string, unknown> = {};
    cycle.self = cycle;
    const bytes = new Uint8Array(4);

    for (const value of [
      { a: shared, b: shared },
      cycle,
      // eslint-disable-next-line no-sparse-arrays -- a hole is the point
      [1, , 3],
      Object.assign([1], { id: "slot" }),
      // eslint-disable-next-line no-sparse-arrays -- a hole is the point
      Object.assign([1, , 3], { slot: "a" }),
      [bytes.subarray(0, 2), bytes.subarray(2)],
      new Blob(["save"]),
      new (class Float9Array extends Uint8Array {})(2),
    ]) {
      expect(() => encode(value)).toThrow(TypeError);
    }
    expect(() => encode([1, 2])).not.toThrow();
  });

  it("restores a snapshot with its versions, stores, indexes, records and key generators", async () => {
    const { takeSnapshot, restoreSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const original = new IDBFactory();
    await seed(original);
    const snapshot = saved(takeSnapshot(original));

    const restored = new IDBFactory();
    await restoreSnapshot(restored, snapshot);

    const db = await done(restored.open("/userfs"));
    expect(db.version).toBe(21);
    const transaction = db.transaction(["FILE_DATA", "counters"], "readwrite");
    const files = transaction.objectStore("FILE_DATA");
    expect(files.index("timestamp").keyPath).toBe("timestamp");
    expect(await done(files.get("/userfs/save.dat"))).toEqual({
      path: "/userfs/save.dat",
      timestamp: new Date(1_700_000_000_000),
      mode: 33206,
      contents: new Int8Array([1, -2, 3]),
    });
    expect(await done(transaction.objectStore("counters").put("second"))).toBe(2);
  });

  it("keeps the key generator above keys whose records were deleted", async () => {
    const { takeSnapshot, restoreSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const original = new IDBFactory();
    await seed(original);
    const db = await done(original.open("/userfs"));
    const transaction = db.transaction("counters", "readwrite");
    const counters = transaction.objectStore("counters");
    counters.put("second");
    counters.delete(2);
    await committed(transaction);
    db.close();

    const restored = new IDBFactory();
    await restoreSnapshot(restored, saved(takeSnapshot(original)));

    const again = await done(restored.open("/userfs"));
    expect(await done(again.transaction("counters", "readwrite").objectStore("counters").put("third"))).toBe(3);
  });

  it("has the snapshot in the save when the build's own commit handler runs, before it can leave", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const save = slot();
    persist(factory, save, Promise.resolve());
    await settle();

    const db = await done(factory.open("/userfs"));
    const transaction = db.transaction("counters", "readwrite");
    transaction.objectStore("counters").put("left right away", 1);
    const atCommit = await new Promise((resolve) => {
      transaction.oncomplete = () => resolve(save.values.at(-1));
    });

    expect(atCommit).toContain("left right away");
  });

  it("takes no snapshot while a write is unfinished, since it may still abort", async () => {
    const { takeSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const db = await done(factory.open("/userfs"));
    const transaction = db.transaction("counters", "readwrite");
    await done(transaction.objectStore("counters").put("not yet", 1));

    expect(takeSnapshot(factory)).toBeNull();
    transaction.abort();
  });

  it("has the snapshot at commit while another write on the same store is still queued", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const save = slot();
    persist(factory, save, Promise.resolve());
    const db = await done(factory.open("/userfs"));

    const first = db.transaction("counters", "readwrite");
    first.objectStore("counters").put("first commit", 1);
    const queued = db.transaction("counters", "readwrite");
    queued.objectStore("counters").put("queued", 2);
    const atCommit = await new Promise((resolve) => {
      first.oncomplete = () => resolve(save.values.at(-1));
    });

    expect(atCommit).toContain("first commit");
    expect(atCommit).not.toContain("queued");
  });

  it("saves a commit that waited on another write once that write aborts", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const save = slot();
    persist(factory, save, Promise.resolve());
    const db = await done(factory.open("/userfs"));

    const kept = db.transaction("counters", "readwrite");
    kept.objectStore("counters").put("kept", 1);
    const aborted = db.transaction("FILE_DATA", "readwrite");
    aborted.objectStore("FILE_DATA").put({ path: "/userfs/other", timestamp: new Date(0) });
    await committed(kept);
    const atAbort = await new Promise<string | null | undefined>((resolve) => {
      aborted.onabort = () => resolve(save.values.at(-1));
      aborted.abort();
    });

    expect(atAbort).toContain("kept");
    expect(atAbort).not.toContain("/userfs/other");
  });

  it("takes a snapshot while only Unity's cache has a write unfinished", async () => {
    const { takeSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const request = factory.open("UnityCache", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("files");
    const cache = await done(request);
    const transaction = cache.transaction("files", "readwrite");
    await done(transaction.objectStore("files").put("asset", "a"));

    expect(takeSnapshot(factory)?.databases.map(({ name }) => name)).toEqual(["/userfs"]);
  });

  it("takes no snapshot while another database's upgrade is unfinished", async () => {
    const { takeSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const request = factory.open("/userfs", 22);
    const during = await new Promise((resolve) => {
      request.onupgradeneeded = () => {
        request.result.createObjectStore("half done");
        resolve(takeSnapshot(factory));
      };
    });

    expect(during).toBeNull();
    (await done(request)).close();
  });

  it("leaves out a database whose first upgrade aborted", async () => {
    const { takeSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const request = factory.open("never created", 1);
    request.onupgradeneeded = () => request.transaction?.abort();
    await done(request).catch(() => undefined);

    expect(takeSnapshot(factory)?.databases.map(({ name }) => name)).toEqual(["/userfs"]);
  });

  it("tells the buyer once when a value cannot be saved, and keeps the last snapshot", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    const save = slot();
    persist(factory, save, Promise.resolve());
    await seed(factory);
    const db = await done(factory.open("/userfs"));

    for (const value of [new Blob(["save"]), "second"]) {
      const transaction = db.transaction("counters", "readwrite");
      transaction.objectStore("counters").put(value);
      await committed(transaction);
    }

    expect(save.failures).toHaveLength(1);
    expect(save.values.at(-1)).not.toContain("second");
  });

  it("lets go of finished transactions, which hold the records they overwrote", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    persist(factory, slot(), Promise.resolve());
    await seed(factory);
    const db = await done(factory.open("/userfs"));

    for (let i = 0; i < 20; i += 1) {
      const transaction = db.transaction("counters", "readwrite");
      transaction.objectStore("counters").put(`save ${i}`, 1);
      await committed(transaction);
    }
    await settle();

    expect(cast<{ _rawDatabase: { transactions: unknown[] } }>(db)._rawDatabase.transactions).toEqual([]);
  });

  it("runs the build's own open after the restore of the same database", async () => {
    const { takeSnapshot, restoreSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const original = new IDBFactory();
    await seed(original);
    const snapshot = saved(takeSnapshot(original));

    const factory = new IDBFactory();
    void restoreSnapshot(factory, snapshot);
    const request = factory.open("/userfs");
    const upgrade = vi.fn();
    request.onupgradeneeded = upgrade;
    const db = await done(request);

    expect(upgrade).not.toHaveBeenCalled();
    expect(await done(db.transaction("FILE_DATA").objectStore("FILE_DATA").count())).toBe(1);
  });

  it("saves a snapshot after each write and after a database is deleted, leaving out Unity's cache", async () => {
    const { persist, restoreSnapshot } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    const save = slot();
    persist(factory, save, Promise.resolve());

    await seed(factory);
    await done(factory.open("UnityCache"));
    await settle();

    const restored = new IDBFactory();
    await restoreSnapshot(restored, cast(JSON.parse(save.values.at(-1) ?? "null")));
    expect((await restored.databases()).map(({ name }) => name)).toEqual(["/userfs"]);
    const db = await done(restored.open("/userfs"));
    expect(await done(db.transaction("counters").objectStore("counters").getAll())).toEqual(["first"]);

    await done(factory.deleteDatabase("/userfs"));
    await settle();
    expect(save.values.at(-1)).toBeNull();
  });

  it("does not save again when a write leaves the databases as they were", async () => {
    const { persist } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const factory = new IDBFactory();
    await seed(factory);
    const save = slot();
    persist(factory, save, Promise.resolve());

    const db = await done(factory.open("/userfs"));
    const first = db.transaction("counters", "readwrite");
    first.objectStore("counters").put("first", 1);
    await committed(first);
    await settle();
    const second = db.transaction("counters", "readwrite");
    second.objectStore("counters").put("first", 1);
    await committed(second);
    await settle();

    expect(save.values).toHaveLength(1);
  });

  it("never overwrites a save it cannot restore", async () => {
    const { install } = loaded.shim;
    for (const saved of ["not JSON", JSON.stringify({ v: 2, databases: [] })]) {
      const save = slot(saved);
      const frame = cast<{ indexedDB: IDBFactory }>({ origin: "null", [loaded.shim.SAVE_SLOT_GLOBAL]: save });
      install(cast(frame));

      await seed(frame.indexedDB);
      await settle();

      expect(save.values).toEqual([]);
      expect(save.failures).toHaveLength(1);
    }
  });

  it("takes the save shim's slot, and puts IndexedDB in place only where the native one cannot be used", async () => {
    const { install, takeSnapshot, SAVE_SLOT_GLOBAL } = loaded.shim;
    const { IDBFactory } = loaded.fake;
    const original = new IDBFactory();
    await seed(original);
    const save = slot(JSON.stringify(takeSnapshot(original)));

    const native = { origin: "https://example.com", indexedDB: "native", [SAVE_SLOT_GLOBAL]: save };
    install(cast(native));
    expect(native.indexedDB).toBe("native");
    expect(SAVE_SLOT_GLOBAL in native).toBe(false);

    const frame = cast<{ indexedDB: IDBFactory; IDBKeyRange: unknown }>({
      origin: "null",
      [SAVE_SLOT_GLOBAL]: save,
    });
    Object.defineProperty(frame, "indexedDB", {
      configurable: true,
      get: () => {
        throw new Error("SecurityError");
      },
    });
    install(cast(frame));

    expect(frame.IDBKeyRange).toBe(loaded.fake.IDBKeyRange);
    expect((await frame.indexedDB.databases()).map(({ name }) => name)).toEqual(["/userfs"]);
    const db = await done(frame.indexedDB.open("/userfs"));
    expect(await done(db.transaction("counters").objectStore("counters").getAll())).toEqual(["first"]);
  });
});
