# frozen_string_literal: true

# The HTML a build's frame gets: the seller's page with the save shim put in front of every script,
# and the CSP that keeps it on an opaque origin even when the URL is opened outside the frame.
module ProductBuilds::PlayerDocument
  SANDBOX = "allow-scripts allow-pointer-lock"
  # How long the shim gathers storage writes before it sends them in one batch.
  SAVE_FLUSH_DELAY_MS = 1_000
  # Browsers cap a beacon (and all keepalive requests together) at 64 KB; a larger last batch goes
  # out as an ordinary request, which the browser may cancel as the page closes.
  SAVE_BEACON_MAX_BYTES = 60_000
  SAVE_FAILED_MESSAGE_TYPE = "gumroad:build-save-failed"
  # Network errors are retried quietly at first; the buyer hears about it only if they keep failing.
  SAVE_FAILURES_BEFORE_ALERT = 3
  # Prefix of the window.name that carries unconfirmed changes from one page of a build to the next.
  CARRIED_CHANGES_PREFIX = "gumroad-build-save:"

  # On the opaque origin, localStorage throws. The shim puts the purchase's save back in its place:
  # reads come from the save served with the page, and writes go in batches (clear, then remove,
  # then set) to the save endpoint under the frame's grant, one batch at a time so they apply in
  # order. The frame has no cookies, so the grant in the URL is the credential, as for its files.
  # On leaving, the last batch goes as a beacon, which the browser still delivers as the page closes.
  # sessionStorage and cookies get the in-memory stand-ins the custom HTML pages use.
  SAVE_SHIM_SCRIPT = <<~JS
    (function () {
      var data = Object.create(null);
      // Parsed, not an object literal, so a "__proto__" key stays a key.
      var saved = JSON.parse(__SAVE__);
      Object.keys(saved).forEach(function (k) { data[k] = String(saved[k]); });
      var carried = null;
      if (typeof window.name === "string" && window.name.indexOf("#{CARRIED_CHANGES_PREFIX}") === 0) {
        try { carried = JSON.parse(window.name.slice(#{CARRIED_CHANGES_PREFIX.length})); } catch (e) {}
        window.name = "";
      }
      var saveUrl = __SAVE_URL__;
      var writer = (Math.random().toString(36) + Date.now().toString(36)).replace(/[^a-z0-9]/g, "").slice(0, #{ProductBuildSave::MAX_WRITER_ID_LENGTH});
      var sequence = 0;
      var pending = null;
      var unconfirmed = null;
      var timer = null;
      var failures = 0;
      function batch() { return pending || (pending = { clear: false, remove: [], set: Object.create(null) }); }
      // Applies newer on top of older, as the server would apply the two one after the other.
      function merge(older, newer) {
        if (!older || (newer && newer.clear)) { return newer; }
        if (!newer) { return older; }
        var result = { clear: older.clear, remove: older.remove.slice(), set: Object.create(null) };
        Object.keys(older.set).forEach(function (k) { result.set[k] = older.set[k]; });
        newer.remove.forEach(function (k) {
          delete result.set[k];
          if (result.remove.indexOf(k) < 0) { result.remove.push(k); }
        });
        Object.keys(newer.set).forEach(function (k) {
          result.set[k] = newer.set[k];
          var i = result.remove.indexOf(k);
          if (i >= 0) { result.remove.splice(i, 1); }
        });
        return result;
      }
      // Each batch is numbered, so the server skips one that arrives after a newer one from this page.
      function body(changes) {
        sequence += 1;
        return JSON.stringify({ clear: changes.clear, remove: changes.remove, set: changes.set, writer: writer, sequence: sequence });
      }
      function failed() {
        try { window.parent.postMessage({ type: "#{SAVE_FAILED_MESSAGE_TYPE}" }, "*"); } catch (e) {}
      }
      // A batch that did not get through goes back in front of newer changes and is sent again.
      function retry(changes) {
        pending = merge(changes, pending);
        failures += 1;
        if (failures === #{SAVE_FAILURES_BEFORE_ALERT}) { failed(); }
      }
      function sendNext() {
        var changes = pending;
        pending = null;
        unconfirmed = changes;
        var payload = body(changes);
        // keepalive lets a small batch finish if the browser discards a hidden tab; only one is ever in flight.
        var small = new Blob([payload]).size <= #{SAVE_BEACON_MAX_BYTES};
        fetch(saveUrl, { method: "POST", body: payload, keepalive: small })
          .then(function (response) {
            if (unconfirmed !== changes) { return; }
            unconfirmed = null;
            if (response.ok) { failures = 0; } else if (response.status >= 500) { retry(changes); } else { failed(); }
          }, function () {
            if (unconfirmed !== changes) { return; }
            unconfirmed = null;
            retry(changes);
          })
          .then(function () { if (pending) { changed(); } });
      }
      function flush() {
        clearTimeout(timer);
        timer = null;
        if (!pending) { return; }
        if (unconfirmed) { changed(); return; }
        sendNext();
      }
      // Everything not yet confirmed, including a batch still in flight, goes in one beacon, which the
      // browser still delivers as the page closes. A reply to the batch in flight is then ignored.
      // The browser may fetch a next page of the build before the beacon lands, so the changes also
      // ride in window.name, which the next page in this frame reads, applies, and sends again.
      function leave() {
        clearTimeout(timer);
        timer = null;
        var changes = merge(unconfirmed, pending);
        unconfirmed = null;
        pending = null;
        if (!changes) { return; }
        var payload = body(changes);
        // The next page keeps this writer and numbers on from this beacon, so if the beacon lands after
        // that page's first save, the server skips it as stale.
        try { window.name = "#{CARRIED_CHANGES_PREFIX}" + JSON.stringify({ writer: writer, sequence: sequence, changes: changes }); } catch (e) {}
        var small = new Blob([payload]).size <= #{SAVE_BEACON_MAX_BYTES};
        if (small && navigator.sendBeacon(saveUrl, payload)) { return; }
        fetch(saveUrl, { method: "POST", body: payload, keepalive: small }).catch(function () {});
      }
      function changed() { if (!timer) { timer = setTimeout(flush, #{SAVE_FLUSH_DELAY_MS}); } }
      var handed = carried && carried.changes;
      if (handed && typeof handed === "object" && Array.isArray(handed.remove) && handed.set && typeof handed.set === "object") {
        if (typeof carried.writer === "string" && typeof carried.sequence === "number") {
          writer = carried.writer;
          sequence = carried.sequence;
        }
        if (handed.clear) { data = Object.create(null); }
        handed.remove.forEach(function (k) { delete data[k]; });
        Object.keys(handed.set).forEach(function (k) { data[k] = String(handed.set[k]); });
        pending = merge(handed, pending);
        changed();
      }
      var api = {
        getItem: function (k) { k = String(k); return k in data ? data[k] : null; },
        setItem: function (k, v) {
          k = String(k); v = String(v);
          data[k] = v;
          var b = batch();
          b.set[k] = v;
          var i = b.remove.indexOf(k);
          if (i >= 0) { b.remove.splice(i, 1); }
          changed();
        },
        removeItem: function (k) {
          k = String(k);
          if (!(k in data)) { return; }
          delete data[k];
          var b = batch();
          delete b.set[k];
          if (b.remove.indexOf(k) < 0) { b.remove.push(k); }
          changed();
        },
        clear: function () {
          data = Object.create(null);
          pending = { clear: true, remove: [], set: Object.create(null) };
          changed();
        },
        key: function (i) { return Object.keys(data)[i] || null; },
        get length() { return Object.keys(data).length; }
      };
      // Games also read and write keys as properties: localStorage.best = 10.
      var storage = new Proxy(api, {
        get: function (t, p) { if (p in api) { return api[p]; } return typeof p === "string" && p in data ? data[p] : undefined; },
        set: function (t, p, v) { if (!(p in api)) { api.setItem(p, v); } return true; },
        deleteProperty: function (t, p) { api.removeItem(p); return true; },
        has: function (t, p) { return p in api || p in data; },
        ownKeys: function () { return Object.keys(data); },
        getOwnPropertyDescriptor: function (t, p) {
          if (typeof p === "string" && p in data) { return { value: data[p], writable: true, enumerable: true, configurable: true }; }
        }
      });
      var throws = false;
      try { void window.localStorage; } catch (e) { throws = true; }
      if (throws) {
        try { Object.defineProperty(window, "localStorage", { value: storage, configurable: true }); } catch (e) {}
      }
      window.addEventListener("pagehide", leave);
      // A hidden tab may never come back, so its changes go now, by the ordinary retried path.
      document.addEventListener("visibilitychange", function () { if (document.visibilityState === "hidden") { flush(); } });
    })();
  JS

  # A UTF-8 byte order mark, leading whitespace and comments, then the doctype if there is one.
  PROLOGUE = /\A(?:\xEF\xBB\xBF)?(?:\s|<!--.*?-->)*(?:<!doctype[^>]*>)?/imn

  # The seller's page is bytes in whatever encoding they wrote it in, so the scripts go in as ASCII
  # bytes right after the doctype, before any tag of the page. There the parser opens <html> and <head>
  # for them, so no tag has to be found, and a <head> inside a comment or a script cannot mislead it.
  # Anything before the doctype would put the page in quirks mode.
  def self.render(html, save_data:, save_url:)
    # ASCII only, so the save reads the same whatever encoding the seller's page is in.
    save = JSON.generate(JSON.generate(save_data, ascii_only: true), ascii_only: true)
    url = JSON.generate(save_url, ascii_only: true)
    # One pass over the template, so a marker inside the saved data is never replaced.
    script = SAVE_SHIM_SCRIPT.gsub(/__SAVE_URL__|__SAVE__/) { ERB::Util.json_escape(_1 == "__SAVE_URL__" ? url : save) }
    # data-cfasync: Rocket Loader must not run the save shim after the in-memory stand-ins.
    injected = %(<script data-cfasync="false">#{script}</script>#{RendersCustomHtmlPages::SANDBOX_COMPAT_SCRIPT}).b
    html = html.b
    html.insert(html.match(PROLOGUE).end(0), injected)
  end

  # `request_origin` is the app or custom-domain origin serving the frame, and `cdn_origin` the
  # host the build's other files redirect to. 'self' is not used: on a sandboxed document it would
  # not match the frame's own URL in every browser.
  def self.content_security_policy(request_origin:, cdn_origin:)
    hosts = "#{request_origin} #{cdn_origin}"
    [
      "sandbox #{SANDBOX}",
      "default-src 'none'",
      "script-src #{hosts} 'unsafe-inline' 'wasm-unsafe-eval' blob:",
      "style-src #{hosts} 'unsafe-inline' blob: data:",
      "img-src #{hosts} blob: data:",
      "media-src #{hosts} blob: data:",
      "font-src #{hosts} blob: data:",
      "connect-src #{hosts} blob: data:",
      "worker-src blob:",
      "frame-ancestors #{request_origin}",
      "form-action 'none'",
      "base-uri 'none'",
    ].join("; ")
  end
end
