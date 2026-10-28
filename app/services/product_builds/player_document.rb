# frozen_string_literal: true

# The HTML a build's frame gets: the seller's page with the save shim put in front of every script,
# and the CSP that keeps it on an opaque origin even when the URL is opened outside the frame.
module ProductBuilds::PlayerDocument
  SANDBOX = "allow-scripts allow-pointer-lock"
  # How long the shim gathers storage writes before it hands them to the parent page in one batch.
  SAVE_FLUSH_DELAY_MS = 1_000
  SAVE_MESSAGE_TYPE = "gumroad:build-save"

  # On the opaque origin, localStorage throws. The shim puts the purchase's save back in its place:
  # reads come from the save served with the page, and writes go to the parent page in batches
  # (clear, then remove, then set), which sends them to the save store. sessionStorage and cookies
  # get the in-memory stand-ins the custom HTML pages use.
  SAVE_SHIM_SCRIPT = <<~JS
    (function () {
      var data = Object.create(null);
      // Parsed, not an object literal, so a "__proto__" key stays a key.
      var saved = JSON.parse(__SAVE__);
      Object.keys(saved).forEach(function (k) { data[k] = String(saved[k]); });
      var pending = null;
      var timer = null;
      function batch() { return pending || (pending = { clear: false, remove: [], set: Object.create(null) }); }
      function flush() {
        clearTimeout(timer);
        timer = null;
        if (!pending) { return; }
        var changes = pending;
        pending = null;
        try { window.parent.postMessage({ type: "#{SAVE_MESSAGE_TYPE}", changes: changes }, "*"); } catch (e) {}
      }
      function changed() { if (!timer) { timer = setTimeout(flush, #{SAVE_FLUSH_DELAY_MS}); } }
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
      window.addEventListener("pagehide", flush);
      document.addEventListener("visibilitychange", function () { if (document.visibilityState === "hidden") { flush(); } });
    })();
  JS

  HEAD_TAG = /<head(?:\s[^>]*)?>/in
  HTML_TAG = /<html(?:\s[^>]*)?>/in

  # The seller's page is bytes in whatever encoding they wrote it in, so the scripts go in as ASCII
  # bytes right after <head> (or <html>, or at the very start), before any script of the page.
  def self.render(html, save_data:)
    script = SAVE_SHIM_SCRIPT.sub("__SAVE__") { ERB::Util.json_escape(save_data.to_json.to_json) }
    injected = "<script>#{script}</script>#{RendersCustomHtmlPages::SANDBOX_COMPAT_SCRIPT}".b
    html = html.b
    tag = html.match(HEAD_TAG) || html.match(HTML_TAG)
    tag ? html.insert(tag.end(0), injected) : injected + html
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
