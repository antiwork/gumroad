// IndexedDB for a web build's sandboxed frame, where the opaque origin makes the native one throw.
// Godot and Unity keep their files in IndexedDB, so this puts an in-memory IndexedDB in its place,
// restored from the purchase's save, and writes the whole of it back as one snapshot after every write.
import {
  IDBCursor,
  IDBCursorWithValue,
  IDBDatabase,
  IDBFactory,
  IDBIndex,
  IDBKeyRange,
  IDBObjectStore,
  IDBOpenDBRequest,
  IDBRequest,
  IDBTransaction,
  IDBVersionChangeEvent,
} from "fake-indexeddb";

import { cast } from "../utils/cast";

// Caches the engine can download again; saving them would fill the save with game assets.
const UNSAVED_DATABASES = new Set(["UnityCache"]);

const SNAPSHOT_VERSION = 1;

export type SaveSlot = { get: () => string | null; set: (value: string | null) => void; fail: () => void };

type Encoded = null | boolean | number | string | Record<string, unknown>;
type IndexSnapshot = { name: string; keyPath: string | string[]; unique: boolean; multiEntry: boolean };
type StoreSnapshot = {
  name: string;
  keyPath: string | string[] | null;
  autoIncrement: boolean;
  // The key generator's current number, which deleted records may have left above every saved key.
  keyGenerator?: number | undefined;
  indexes: IndexSnapshot[];
  records: [Encoded, Encoded][];
};
type DatabaseSnapshot = { name: string; version: number; stores: StoreSnapshot[] };
type Snapshot = { v: number; databases: DatabaseSnapshot[] };

// Bytes passed to one String.fromCharCode call, well under the engines' argument limits.
const BASE64_CHUNK_BYTES = 0x8000;
const bytesToBase64 = (bytes: Uint8Array) => {
  let binary = "";
  for (let i = 0; i < bytes.length; i += BASE64_CHUNK_BYTES) {
    binary += String.fromCharCode(...bytes.subarray(i, i + BASE64_CHUNK_BYTES));
  }
  return btoa(binary);
};
const base64ToBytes = (base64: string) => {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
};

const TYPED_ARRAYS: Record<string, new (buffer: ArrayBuffer, offset: number, length: number) => ArrayBufferView> = {
  Int8Array,
  Uint8Array,
  Uint8ClampedArray,
  Int16Array,
  Uint16Array,
  Int32Array,
  Uint32Array,
  Float32Array,
  Float64Array,
  BigInt64Array,
  BigUint64Array,
  DataView,
};

// A stored value as JSON. Every object is wrapped in a one-key tag, so a value of the build's own
// that looks like a tag still comes back as itself. What JSON cannot carry exactly (an object reached
// twice or in a cycle, an array with holes or extra properties, a Blob) throws: the buyer is told, and
// the save keeps the last snapshot, instead of a restore that differs from what the build stored.
export const encode = (value: unknown, seen = new Set<unknown>()): Encoded => {
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") {
    if (Object.is(value, -0)) return { n: "-0" };
    return Number.isFinite(value) ? value : { n: String(value) };
  }
  if (typeof value === "undefined") return { u: 1 };
  if (typeof value === "bigint") return { i: value.toString() };
  const shared = (object: unknown) => {
    if (seen.has(object)) throw new TypeError("Cannot save an object stored in two places");
    seen.add(object);
  };
  shared(value);
  const inner = (v: unknown) => encode(v, seen);
  if (value instanceof Date) {
    const time = value.getTime();
    return { d: Number.isNaN(time) ? "NaN" : time };
  }
  if (value instanceof ArrayBuffer) return { b: bytesToBase64(new Uint8Array(value)), t: "ArrayBuffer" };
  if (ArrayBuffer.isView(value)) {
    if (!(value.constructor.name in TYPED_ARRAYS)) throw new TypeError("Cannot save this view");
    // The whole buffer, as structured cloning keeps it, with where the view sits in it.
    shared(value.buffer);
    return {
      b: bytesToBase64(new Uint8Array(value.buffer)),
      t: value.constructor.name,
      o: value.byteOffset,
      l: value instanceof DataView ? value.byteLength : cast<{ length: number }>(value).length,
    };
  }
  if (Array.isArray(value)) {
    const keys = Object.keys(value);
    if (keys.length !== value.length || keys.some((k, i) => k !== String(i))) {
      throw new TypeError("Cannot save this array");
    }
    return { a: value.map(inner) };
  }
  if (value instanceof Map) return { m: [...value].map(([k, v]) => [inner(k), inner(v)]) };
  if (value instanceof Set) return { s: [...value].map(inner) };
  const prototype: unknown = typeof value === "object" ? Object.getPrototypeOf(value) : undefined;
  if (prototype === Object.prototype || prototype === null) {
    return { o: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, inner(v)])) };
  }
  throw new TypeError("Cannot save this value");
};

export const decode = (encoded: Encoded): unknown => {
  if (encoded === null || typeof encoded !== "object") return encoded;
  const [tag, body] = Object.entries(encoded)[0] ?? [];
  switch (tag) {
    case "n":
      return String(body) === "-0" ? -0 : Number(body);
    case "u":
      return undefined;
    case "i":
      return BigInt(String(body));
    case "d":
      return new Date(Number(body));
    case "b": {
      const bytes = base64ToBytes(String(body));
      const type = String(encoded.t);
      if (type === "ArrayBuffer") return bytes.buffer;
      const View = TYPED_ARRAYS[type] ?? Uint8Array;
      return new View(bytes.buffer, Number(encoded.o), Number(encoded.l));
    }
    case "a":
      return cast<Encoded[]>(body).map(decode);
    case "m":
      return new Map(cast<[Encoded, Encoded][]>(body).map(([k, v]) => [decode(k), decode(v)]));
    case "s":
      return new Set(cast<Encoded[]>(body).map(decode));
    case "o": {
      // A "__proto__" entry must stay an own key, as the structured clone kept it.
      const object: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(cast<Record<string, Encoded>>(body))) {
        Object.defineProperty(object, k, { value: decode(v), enumerable: true, writable: true, configurable: true });
      }
      return object;
    }
    default:
      throw new TypeError(`Unknown saved value tag ${String(tag)}`);
  }
};

// The library keeps state the IndexedDB API does not expose, in plain maps. The pinned version's
// internals let a snapshot be read at once, in the commit event, and let go of finished transactions;
// the tests cover both.
type RawStore = {
  name: string;
  keyPath: string | string[] | null;
  autoIncrement: boolean;
  keyGenerator: { num: number } | null;
  rawIndexes: Map<string, IndexSnapshot>;
  records: { values: () => Iterable<{ key: unknown; value: unknown }> };
};
type RawTransaction = { mode: IDBTransactionMode; _started: boolean; _state: string; _rollbackLog: unknown[] };
type RawDatabase = {
  name: string;
  version: number;
  rawObjectStores: Map<string, RawStore>;
  transactions: RawTransaction[];
};
const rawDatabases = (factory: IDBFactory) => cast<{ _databases: Map<string, RawDatabase> }>(factory)._databases;

export const done = <T>(request: IDBRequest<T>) =>
  new Promise<T>((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });

// A started write's changes are already in the records, and it may still abort; a queued one has
// changed nothing. An upgrade changes the schema before it starts, so it counts as soon as it exists.
const unfinished = (tx: RawTransaction) =>
  tx._state !== "finished" && (tx.mode === "versionchange" || (tx.mode === "readwrite" && tx._started));

// Null while a write is unfinished; that write's own commit or abort takes the next snapshot.
export const takeSnapshot = (factory: IDBFactory): Snapshot | null => {
  // Version 0 is a database whose first upgrade aborted; it does not exist for the build.
  const saved = [...rawDatabases(factory).values()].filter((db) => !UNSAVED_DATABASES.has(db.name) && db.version !== 0);
  if (saved.some((db) => db.transactions.some(unfinished))) return null;
  const databases = saved.map((db) => ({
    name: db.name,
    version: db.version,
    stores: [...db.rawObjectStores.values()].map((store) => ({
      name: store.name,
      keyPath: store.keyPath,
      autoIncrement: store.autoIncrement,
      keyGenerator: store.keyGenerator?.num,
      indexes: [...store.rawIndexes.values()].map(({ name, keyPath, unique, multiEntry }) => ({
        name,
        keyPath,
        unique,
        multiEntry,
      })),
      records: [...store.records.values()].map(({ key, value }): [Encoded, Encoded] => [encode(key), encode(value)]),
    })),
  }));
  return { v: SNAPSHOT_VERSION, databases };
};

// The library keeps every transaction, with the records it overwrote, for as long as the database
// lives; a game that autosaves would hold every old save in memory. Finished ones are only ever
// skipped, so they are dropped once the library is done with them.
const release = (transaction: IDBTransaction) => {
  const drop = () =>
    setTimeout(() => {
      const state = cast<RawTransaction>(transaction);
      if (state._state !== "finished") return;
      state._rollbackLog = [];
      const all = cast<{ _rawDatabase: RawDatabase }>(transaction.db)._rawDatabase.transactions;
      const i = all.indexOf(state);
      if (i >= 0) all.splice(i, 1);
    });
  transaction.addEventListener("complete", drop);
  transaction.addEventListener("abort", drop);
};

// Opens each database at its saved version and fills it in the upgrade. The factory runs opens of one
// name in the order they were made, so a build's own open of the same database waits for this one.
export const restoreSnapshot = (factory: IDBFactory, snapshot: Snapshot) =>
  Promise.all(
    snapshot.databases.map(async (saved) => {
      const request = factory.open(saved.name, saved.version);
      request.onupgradeneeded = () => {
        const db = request.result;
        for (const savedStore of saved.stores) {
          const store = db.createObjectStore(savedStore.name, {
            keyPath: savedStore.keyPath,
            autoIncrement: savedStore.autoIncrement,
          });
          for (const index of savedStore.indexes) {
            store.createIndex(index.name, index.keyPath, { unique: index.unique, multiEntry: index.multiEntry });
          }
          for (const [key, value] of savedStore.records) {
            if (savedStore.keyPath === null) store.put(decode(value), cast<IDBValidKey>(decode(key)));
            else store.put(decode(value));
          }
          const generator = cast<{ _rawObjectStore: RawStore }>(store)._rawObjectStore.keyGenerator;
          if (generator && savedStore.keyGenerator !== undefined) {
            generator.num = Math.max(generator.num, savedStore.keyGenerator);
          }
        }
      };
      (await done(request)).close();
    }),
  );

// Takes a snapshot in the commit event of every write, and when a database is deleted, so the save
// shim holds it before the build can leave the page. A value the snapshot cannot hold tells the buyer,
// and the save keeps the last snapshot that worked.
export const persist = (factory: IDBFactory, slot: SaveSlot, ready: Promise<unknown>) => {
  let restored = false;
  let missed = false;
  let failed = false;
  let last = slot.get();
  const save = () => {
    if (!restored) {
      missed = true;
      return;
    }
    let snapshot;
    try {
      snapshot = takeSnapshot(factory);
    } catch {
      if (!failed) slot.fail();
      failed = true;
      return;
    }
    failed = false;
    if (!snapshot) return;
    const value = snapshot.databases.length > 0 ? JSON.stringify(snapshot) : null;
    if (value !== last) slot.set((last = value));
  };
  // A restore that failed leaves `restored` false, so the save it could not read is never overwritten.
  ready.then(
    () => {
      restored = true;
      if (missed) save();
    },
    () => slot.fail(),
  );

  // Registered before the build can set its own handlers, so the snapshot is taken first. Upgrades come
  // through here too: the library opens them with `transaction()`, after this patch is in place.
  const watch = (transaction: IDBTransaction) => {
    release(transaction);
    if (transaction.mode !== "readonly") {
      transaction.addEventListener("complete", save);
      // A commit skips its snapshot while another write is unfinished; when that one aborts instead,
      // this takes it, after the library has rolled the aborted one back.
      transaction.addEventListener("abort", save);
    }
  };

  // eslint-disable-next-line @typescript-eslint/unbound-method -- applied to `this` below
  const transaction = IDBDatabase.prototype.transaction;
  IDBDatabase.prototype.transaction = function (this: IDBDatabase, ...args: Parameters<typeof transaction>) {
    const result = transaction.apply(this, args);
    watch(result);
    return result;
  };
  const deleteDatabase = factory.deleteDatabase.bind(factory);
  factory.deleteDatabase = (...args: Parameters<typeof deleteDatabase>) => {
    const request = deleteDatabase(...args);
    request.addEventListener("success", save);
    return request;
  };
};

// The save shim leaves its slot for the snapshot on the window, for this script alone to take.
export const SAVE_SLOT_GLOBAL = "__gumroadIndexedDBSaveSlot";

export const install = (target: Window & typeof globalThis) => {
  const slot = cast<SaveSlot | undefined>(Reflect.get(target, SAVE_SLOT_GLOBAL));
  Reflect.deleteProperty(target, SAVE_SLOT_GLOBAL);
  let usable = target.origin !== "null";
  try {
    void target.indexedDB;
  } catch {
    usable = false;
  }
  if (usable) return;

  const factory = new IDBFactory();
  const globals: Record<string, unknown> = {
    indexedDB: factory,
    IDBCursor,
    IDBCursorWithValue,
    IDBDatabase,
    IDBFactory,
    IDBIndex,
    IDBKeyRange,
    IDBObjectStore,
    IDBOpenDBRequest,
    IDBRequest,
    IDBTransaction,
    IDBVersionChangeEvent,
  };
  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(target, name, { value, writable: true, configurable: true });
  }
  if (!slot) return;

  // A save this cannot read or restore is never overwritten: `ready` rejects, so persist saves nothing.
  const saved = slot.get();
  let ready: Promise<unknown> = Promise.resolve();
  if (saved) {
    try {
      const snapshot = cast<Snapshot>(JSON.parse(saved));
      if (snapshot.v !== SNAPSHOT_VERSION) throw new Error(`Unknown snapshot version ${String(snapshot.v)}`);
      ready = restoreSnapshot(factory, snapshot);
    } catch {
      ready = Promise.reject(new Error("The saved IndexedDB cannot be restored"));
    }
  }
  // Opens wait for the restore in the per-name queue; listing the databases has no queue, so it waits here.
  const databases = factory.databases.bind(factory);
  factory.databases = () => ready.then(databases, databases);
  persist(factory, slot, ready);
};
