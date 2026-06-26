# frozen_string_literal: true

# Shared machinery for rendering seller-authored custom HTML inside a
# sandboxed, strictly-CSP'd document. Both product landing pages
# (LinksController) and profile landing pages (UsersController) render the
# same opaque-origin iframe content, so the CSP, the storage-shim script, and
# the inlined Tailwind build all live here to stay in lockstep — a drift
# between the two surfaces would be a security regression, not a cosmetic one.
module RendersCustomHtmlPages
  extend ActiveSupport::Concern

  PAGE_ASSET_HOSTS = [CDN_S3_PROXY_HOST, PUBLIC_STORAGE_CDN_S3_PROXY_HOST].compact.uniq.join(" ")

  CUSTOM_HTML_CSP = [
    # Sandbox the response itself, not just the wrapper's iframe attribute.
    # A visitor can navigate straight to the /landing/embed endpoint (top-level,
    # not framed), where the iframe sandbox doesn't apply — without this the
    # seller's inline scripts would run on the real subdomain origin. Matches
    # the wrapper iframe's sandbox: scripts + forms + popups, no same-origin/top-nav.
    "sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox",
    "default-src 'none'",
    "script-src 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com",
    "style-src 'unsafe-inline' https://cdn.tailwindcss.com https://fonts.googleapis.com https://fonts.bunny.net",
    "frame-src https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com",
    "img-src data: blob: #{PAGE_ASSET_HOSTS}",
    # Mirror img-src so the <audio>/<video>/<source> tags the sanitizer
    # allows actually load — without this they'd inherit default-src 'none'.
    "media-src data: blob: #{PAGE_ASSET_HOSTS}",
    "font-src data: https://fonts.gstatic.com https://fonts.bunny.net",
    "connect-src 'none'",
    "form-action 'self'",
  ].join("; ") + ";"

  # Loaded in <head> so it runs before any seller script (without becoming the
  # body's first child). On the opaque origin (allow-scripts, no
  # allow-same-origin) localStorage/sessionStorage/document.cookie throw, so a
  # seller script reading them on load throws and halts — commonly a theme
  # toggle — leaving the page blank. In-memory stand-ins let those scripts run
  # instead of throwing; nothing persists, which already matched this origin.
  # data-cfasync stops Rocket Loader deferring it.
  SANDBOX_COMPAT_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-sandbox-shim>
      (function () {
        function memStorage() {
          var store = Object.create(null);
          return {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
            setItem: function (k, v) { store[k] = String(v); },
            removeItem: function (k) { delete store[k]; },
            clear: function () { store = {}; },
            key: function (i) { return Object.keys(store)[i] || null; },
            get length() { return Object.keys(store).length; }
          };
        }
        ["localStorage", "sessionStorage"].forEach(function (name) {
          var throws = false;
          try { void window[name]; } catch (e) { throws = true; }
          if (throws) {
            try { Object.defineProperty(window, name, { value: memStorage(), configurable: true }); } catch (e) {}
          }
        });
        var cookieThrows = false;
        try { void document.cookie; } catch (e) { cookieThrows = true; }
        if (cookieThrows) {
          var jar = Object.create(null);
          try {
            Object.defineProperty(document, "cookie", {
              configurable: true,
              get: function () { return Object.keys(jar).map(function (k) { return k + "=" + jar[k]; }).join("; "); },
              set: function (v) {
                var first = String(v).split(";")[0];
                var eq = first.indexOf("=");
                if (eq < 1) { return; }
                jar[first.slice(0, eq).trim()] = first.slice(eq + 1).trim();
              }
            });
          } catch (e) {}
        }
      })();
    </script>
  HTML

  POLL_INTERVAL_MS = 2000

  PROFILE_FIELDS_PREVIEW_SCRIPT = <<~HTML
    <script data-cfasync="false">
      window.addEventListener("message", function (e) {
        var d = e.data;
        if (!d || d.type !== "gumroad:profile-fields") return;
        ["name", "bio"].forEach(function (field) {
          var value = d[field] == null ? "" : String(d[field]);
          var nodes = document.querySelectorAll('[data-gumroad-field="' + field + '"]');
          for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
        });
      });
    </script>
  HTML

  module ClassMethods
    # Memoized per process — the file ships with the deployed artifact and
    # only changes on deploy, which restarts the process.
    def pages_tailwind_inline
      path = Rails.root.join("public/pages-tailwind.css")
      return "" unless File.exist?(path)

      @pages_tailwind_inline ||= "<style>#{File.read(path)}</style>"
    end
  end

  private
    def render_landing_version(visible:, page:)
      render json: { present: visible, version: visible ? page&.updated_at&.to_i : nil }
    end

    def custom_html_live_reload_script(version_src:, nonce:)
      <<~HTML
        <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false">
          (function () {
            var frame = document.getElementById("gumroad-landing-frame");
            var versionUrl = #{ERB::Util.json_escape(version_src.to_json)};
            var known = null;
            function poll() {
              if (document.hidden) return;
              fetch(versionUrl, { headers: { "Accept": "application/json" }, cache: "no-store", credentials: "same-origin" })
                .then(function (r) { return r.ok ? r.json() : null; })
                .then(function (data) {
                  if (!data) return;
                  var current = data.present ? "v" + String(data.version) : "absent";
                  if (known === null) { known = current; return; }
                  if (current === known) return;
                  if (current === "absent") { window.location.reload(); return; }
                  known = current;
                  if (frame) frame.src = frame.src.split("#")[0].split("?")[0] + "?" + encodeURIComponent(current);
                })
                .catch(function () {});
            }
            setInterval(poll, #{POLL_INTERVAL_MS});
            poll();
          })();
        </script>
      HTML
    end

    # The landing iframe HTML must reflect a just-published edit, so read from the
    # primary rather than a possibly-lagging replica. Wired via a before_action in
    # each controller (the product and profile embed actions both need it).
    def stick_to_primary_for_landing_iframe
      ActiveRecord::Base.connection.stick_to_primary!
    end

    # Opt out of SecureHeaders' default CSP so the strict, seller-scoped CSP we
    # set below survives. Without this, the middleware overwrites our header
    # with the app default (no 'unsafe-inline'), silently blocking the seller's
    # inline scripts. X-Frame-Options and Referrer-Policy aren't managed by
    # SecureHeaders here, so setting those directly is fine.
    def apply_custom_html_response_headers
      SecureHeaders.opt_out_of_header(request, :csp)
      response.set_header("Content-Security-Policy", CUSTOM_HTML_CSP)
      response.set_header("X-Frame-Options", "SAMEORIGIN")
      response.set_header("Referrer-Policy", "no-referrer")
    end
end
