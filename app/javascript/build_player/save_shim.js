// Runs first inside a web build's sandboxed frame, injected by ProductBuilds::PlayerDocument, which
// replaces __CONFIG__ with its settings and the purchase's save. Plain ES5 in one function: it is not
// bundled, and it must run before any script of the seller's page.
//
// On the opaque origin, localStorage throws. This puts the purchase's save back in its place: reads
// come from the save served with the page, and writes go in batches (clear, then remove, then set) to
// the save endpoint in config.saveUrl, one batch at a time. The frame has no cookies, so the grant in
// that URL is the credential. Each batch is numbered for this page load (the writer), so the server
// skips one that arrives after a newer one; a batch that fails goes back in front of newer changes
// and is sent again.
//
// The IndexedDB shim keeps its snapshot in the same save, under config.indexedDBKey. That key is
// reached only through the slot left on the window for it; the build's localStorage never shows it.
/* global __CONFIG__ */
(function () {
  const config = JSON.parse(__CONFIG__);
  let data = Object.create(null);
  // config.save comes from JSON.parse, so a "__proto__" key is a key, not a prototype.
  Object.keys(config.save).forEach((k) => {
    data[k] = String(config.save[k]);
  });

  // A build page that opened another page hands it every change it made, in window.name, because the
  // browser may fetch the next page before even a confirmed batch lands.
  let carried = null;
  if (typeof window.name === "string" && window.name.indexOf(config.carriedPrefix) === 0) {
    try {
      carried = JSON.parse(window.name.slice(config.carriedPrefix.length));
    } catch {}
    window.name = "";
  }

  const saveUrl = config.saveUrl;
  let writer = (Math.random().toString(36) + Date.now().toString(36))
    .replace(/[^a-z0-9]/gu, "")
    .slice(0, config.maxWriterIdLength);
  let sequence = 0;
  let pending = null;
  let unconfirmed = null;
  let sincePageLoad = null;
  // Changes made after a hide beacon went out, and that beacon's own changes and the bytes it took of
  // the keepalive quota; null while no hide beacon is outstanding.
  let sinceHidden = null;
  let hiddenBeaconChanges = null;
  let hiddenBeaconBytes = 0;
  let timer = null;
  let failures = 0;

  function emptyBatch() {
    return { clear: false, remove: [], set: Object.create(null) };
  }
  function batch() {
    return (pending ||= emptyBatch());
  }
  function isEmpty(b) {
    return !b.clear && b.remove.length === 0 && Object.keys(b.set).length === 0;
  }
  function recordingBatches() {
    return sinceHidden ? [batch(), pageBatch(), sinceHidden] : [batch(), pageBatch()];
  }
  function pageBatch() {
    return (sincePageLoad ||= emptyBatch());
  }

  // Applies newer on top of older, as the server would apply the two one after the other.
  function merge(older, newer) {
    if (!older || (newer && newer.clear)) {
      return newer;
    }
    if (!newer) {
      return older;
    }
    const result = { clear: older.clear, remove: older.remove.slice(), set: Object.create(null) };
    Object.keys(older.set).forEach((k) => {
      result.set[k] = older.set[k];
    });
    newer.remove.forEach((k) => {
      delete result.set[k];
      if (result.remove.indexOf(k) < 0) {
        result.remove.push(k);
      }
    });
    Object.keys(newer.set).forEach((k) => {
      result.set[k] = newer.set[k];
      const i = result.remove.indexOf(k);
      if (i >= 0) {
        result.remove.splice(i, 1);
      }
    });
    return result;
  }

  function body(changes) {
    sequence += 1;
    return JSON.stringify({
      clear: changes.clear,
      remove: changes.remove,
      set: changes.set,
      writer,
      sequence,
    });
  }

  function failed() {
    try {
      window.parent.postMessage({ type: config.failedMessageType }, "*");
    } catch {}
  }

  function retry(changes) {
    pending = merge(changes, pending);
    failures += 1;
    if (failures === config.failuresBeforeAlert) {
      failed();
    }
  }

  // Ordinary batches do not use keepalive: the browser's 64 KB keepalive quota is kept whole for the
  // beacons below.
  function sendNext() {
    const changes = pending;
    pending = null;
    unconfirmed = changes;
    fetch(saveUrl, { method: "POST", body: body(changes) })
      .then(
        (response) => {
          if (unconfirmed !== changes) {
            return;
          }
          unconfirmed = null;
          if (response.ok) {
            failures = 0;
          } else if (response.status >= 500) {
            retry(changes);
          } else {
            failed();
          }
        },
        () => {
          if (unconfirmed !== changes) {
            return;
          }
          unconfirmed = null;
          retry(changes);
        },
      )
      .then(() => {
        if (pending) {
          changed();
        }
      });
  }

  function flush() {
    clearTimeout(timer);
    timer = null;
    if (!pending) {
      return;
    }
    if (unconfirmed) {
      changed();
      return;
    }
    sendNext();
  }

  function changed() {
    if (!timer) {
      timer = setTimeout(flush, config.flushDelayMs);
    }
  }

  // A beacon is delivered even as the page closes, but the browser only says it was queued.
  // Returns the size it sent, for a later beacon that has to share the quota with this one.
  function beacon(changes, maxBytes) {
    const payload = body(changes);
    const size = new Blob([payload]).size;
    if (size <= maxBytes && navigator.sendBeacon(saveUrl, payload)) {
      return size;
    }
    fetch(saveUrl, { method: "POST", body: payload }).catch(() => {});
    return 0;
  }

  // A hidden tab may be discarded without another event, so its unconfirmed changes go as a beacon
  // now. They also stay queued and go again by the ordinary retried path, in case the beacon did not
  // get through; sending a change twice is harmless.
  function hidden() {
    const changes = merge(unconfirmed, pending);
    if (!changes) {
      return;
    }
    unconfirmed = null;
    pending = changes;
    // A copy: `changes` is also `pending`, which later writes change.
    hiddenBeaconChanges = merge(changes, emptyBatch());
    hiddenBeaconBytes = beacon(changes, config.beaconMaxBytes);
    sinceHidden = emptyBatch();
    changed();
  }
  // Everything unconfirmed, including a batch still in flight, goes in one beacon; a reply to the batch
  // in flight is then ignored. When a hide beacon is outstanding (closing a tab fires hidden, then
  // pagehide), it already holds all of that, so only the changes made since go, in the quota it left.
  // The server orders each key by writer and number, so the two beacons apply in either order. The one
  // dependency is room: arriving first, the new keys must not hit the save's limits because the hide
  // beacon's clear or removals have not applied yet. So the leave beacon repeats those removals, which
  // are small and harmless twice, and after a clear it carries the whole hide beacon too. The next page
  // keeps this writer and numbers on from the beacon, so its saves are ordered after it too.
  function leave() {
    clearTimeout(timer);
    timer = null;
    let changes = merge(unconfirmed, pending);
    let maxBytes = config.beaconMaxBytes;
    if (sinceHidden) {
      maxBytes -= hiddenBeaconBytes;
      if (isEmpty(sinceHidden)) {
        changes = null;
      } else if (hiddenBeaconChanges.clear) {
        changes = merge(hiddenBeaconChanges, sinceHidden);
      } else {
        changes = merge({ clear: false, remove: hiddenBeaconChanges.remove, set: Object.create(null) }, sinceHidden);
      }
    }
    unconfirmed = null;
    pending = null;
    if (changes) {
      beacon(changes, maxBytes);
    }
    if (sincePageLoad) {
      try {
        window.name = config.carriedPrefix + JSON.stringify({ writer, sequence, changes: sincePageLoad });
      } catch {}
    }
  }

  const handed = carried && carried.changes;
  if (
    handed &&
    typeof handed === "object" &&
    Array.isArray(handed.remove) &&
    handed.set &&
    typeof handed.set === "object"
  ) {
    if (typeof carried.writer === "string" && typeof carried.sequence === "number") {
      writer = carried.writer;
      sequence = carried.sequence;
    }
    if (handed.clear) {
      data = Object.create(null);
    }
    handed.remove.forEach((k) => {
      delete data[k];
    });
    Object.keys(handed.set).forEach((k) => {
      data[k] = String(handed.set[k]);
    });
    pending = merge(handed, pending);
    sincePageLoad = merge(handed, sincePageLoad);
    changed();
  }

  const hiddenKey = config.indexedDBKey;
  function visible(k) {
    return k !== hiddenKey && k in data;
  }
  function visibleKeys() {
    return Object.keys(data).filter((k) => k !== hiddenKey);
  }

  function put(k, v) {
    data[k] = v;
    recordingBatches().forEach((b) => {
      b.set[k] = v;
      const i = b.remove.indexOf(k);
      if (i >= 0) {
        b.remove.splice(i, 1);
      }
    });
    changed();
  }
  function drop(k) {
    if (!(k in data)) {
      return;
    }
    delete data[k];
    recordingBatches().forEach((b) => {
      delete b.set[k];
      if (b.remove.indexOf(k) < 0) {
        b.remove.push(k);
      }
    });
    changed();
  }

  const api = {
    getItem(k) {
      k = String(k);
      return visible(k) ? data[k] : null;
    },
    setItem(k, v) {
      k = String(k);
      if (k !== hiddenKey) {
        put(k, String(v));
      }
    },
    removeItem(k) {
      k = String(k);
      if (k !== hiddenKey) {
        drop(k);
      }
    },
    // Clears the build's keys; the IndexedDB snapshot goes back in after the clear.
    clear() {
      const snapshot = data[hiddenKey];
      data = Object.create(null);
      pending = { clear: true, remove: [], set: Object.create(null) };
      sincePageLoad = { clear: true, remove: [], set: Object.create(null) };
      if (sinceHidden) {
        sinceHidden = { clear: true, remove: [], set: Object.create(null) };
      }
      changed();
      if (snapshot !== undefined) {
        put(hiddenKey, snapshot);
      }
    },
    key(i) {
      return visibleKeys()[i] || null;
    },
    get length() {
      return visibleKeys().length;
    },
  };
  // Games also read and write keys as properties: localStorage.best = 10.
  const storage = new Proxy(api, {
    get(t, p) {
      if (p in api) {
        return api[p];
      }
      return typeof p === "string" && visible(p) ? data[p] : undefined;
    },
    set(t, p, v) {
      if (!(p in api)) {
        api.setItem(p, v);
      }
      return true;
    },
    deleteProperty(t, p) {
      api.removeItem(p);
      return true;
    },
    has(t, p) {
      return p in api || (typeof p === "string" && visible(p));
    },
    ownKeys() {
      return visibleKeys();
    },
    getOwnPropertyDescriptor(t, p) {
      if (typeof p === "string" && visible(p)) {
        return { value: data[p], writable: true, enumerable: true, configurable: true };
      }
    },
  });
  let throws = false;
  try {
    void window.localStorage;
  } catch {
    throws = true;
  }
  if (throws) {
    try {
      Object.defineProperty(window, "localStorage", { value: storage, configurable: true });
    } catch {}
  }
  Object.defineProperty(window, config.indexedDBSlotGlobal, {
    value: {
      get() {
        return hiddenKey in data ? data[hiddenKey] : null;
      },
      set(v) {
        if (v === null) {
          drop(hiddenKey);
        } else {
          put(hiddenKey, v);
        }
      },
      fail: failed,
    },
    configurable: true,
  });
  window.addEventListener("pagehide", leave);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      hidden();
    } else {
      sinceHidden = null;
      hiddenBeaconChanges = null;
      hiddenBeaconBytes = 0;
    }
  });
})();
