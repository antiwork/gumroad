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
  // Changes made after a hide beacon went out; null while no hide beacon is outstanding.
  let sinceHidden = null;
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
  function beacon(changes) {
    const payload = body(changes);
    if (new Blob([payload]).size <= config.beaconMaxBytes && navigator.sendBeacon(saveUrl, payload)) {
      return;
    }
    fetch(saveUrl, { method: "POST", body: payload }).catch(() => {});
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
    beacon(changes);
    sinceHidden = emptyBatch();
    changed();
  }
  // Everything unconfirmed, including a batch still in flight, goes in one beacon; a reply to the batch
  // in flight is then ignored. When a hide beacon is outstanding (closing a tab fires hidden, then
  // pagehide), it already holds all of that, so only the changes made since go now: two full beacons
  // could together pass the browser's keepalive quota, and the second would be dropped. The next page
  // keeps this writer and numbers on from the beacon, so if the beacon lands after that page's first
  // save, the server skips it as stale.
  function leave() {
    clearTimeout(timer);
    timer = null;
    const changes = sinceHidden ? (isEmpty(sinceHidden) ? null : sinceHidden) : merge(unconfirmed, pending);
    unconfirmed = null;
    pending = null;
    if (changes) {
      beacon(changes);
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

  const api = {
    getItem(k) {
      k = String(k);
      return k in data ? data[k] : null;
    },
    setItem(k, v) {
      k = String(k);
      v = String(v);
      data[k] = v;
      recordingBatches().forEach((b) => {
        b.set[k] = v;
        const i = b.remove.indexOf(k);
        if (i >= 0) {
          b.remove.splice(i, 1);
        }
      });
      changed();
    },
    removeItem(k) {
      k = String(k);
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
    },
    clear() {
      data = Object.create(null);
      pending = { clear: true, remove: [], set: Object.create(null) };
      sincePageLoad = { clear: true, remove: [], set: Object.create(null) };
      if (sinceHidden) {
        sinceHidden = { clear: true, remove: [], set: Object.create(null) };
      }
      changed();
    },
    key(i) {
      return Object.keys(data)[i] || null;
    },
    get length() {
      return Object.keys(data).length;
    },
  };
  // Games also read and write keys as properties: localStorage.best = 10.
  const storage = new Proxy(api, {
    get(t, p) {
      if (p in api) {
        return api[p];
      }
      return typeof p === "string" && p in data ? data[p] : undefined;
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
      return p in api || p in data;
    },
    ownKeys() {
      return Object.keys(data);
    },
    getOwnPropertyDescriptor(t, p) {
      if (typeof p === "string" && p in data) {
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
  window.addEventListener("pagehide", leave);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      hidden();
    } else {
      sinceHidden = null;
    }
  });
})();
