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

  # CUSTOM_HTML_CSP for documents delivered without response headers — e.g. the agent's
  # proposed-change preview, which reaches the browser as an iframe srcdoc. A meta CSP tag can't
  # carry the `sandbox` directive (browsers ignore it there), so it's stripped; the embedding
  # iframe's sandbox attribute supplies the sandboxing instead. Everything else applies unchanged,
  # so a previewed page blocks exactly the resources (external images, fetches, ...) the live page
  # would block.
  CUSTOM_HTML_META_CSP = CUSTOM_HTML_CSP.split("; ").reject { |directive| directive.start_with?("sandbox ") }.join("; ")

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

  # The HTML comment the agent-preview endpoint splices in front of an edit's replacement so the
  # preview can find where the page changed. Chosen as a comment because Ai::PageSanitizer passes
  # comments through untouched and they render as nothing, so a page marked this way is
  # byte-for-byte the page the seller would publish (the preview controller verifies that before
  # serving the marked variant).
  PREVIEW_CHANGED_MARKER_TEXT = "gumroad-preview-changed"
  PREVIEW_CHANGED_MARKER = "<!--#{PREVIEW_CHANGED_MARKER_TEXT}-->"

  # Injected only into the agent's proposed-change preview document (never the live page). An edit
  # can land anywhere on the page, and the preview iframe is opaque-origin so the dashboard can't
  # scroll it from outside — without this the preview always opens at the top and an edit further
  # down looks like no change at all. Finds the marker comment the preview endpoint spliced in
  # front of the replacement and scrolls the surrounding content into view; when the marker is
  # absent (whole-page updates, or a marker the endpoint had to discard) it does nothing and the
  # preview opens at the top as before.
  PREVIEW_SCROLL_TO_CHANGE_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-preview-scroll>
      (function () {
        function scrollToChange() {
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_COMMENT, null);
          var node;
          while ((node = walker.nextNode())) {
            if (node.nodeValue !== "#{PREVIEW_CHANGED_MARKER_TEXT}") continue;
            // The marker sits immediately before the replacement: when the replacement starts
            // with an element that element is the change; when it's bare text, the enclosing
            // element is the closest thing to "the changed area".
            var target = node.nextElementSibling || node.parentElement;
            if (target && target !== document.body) target.scrollIntoView({ block: "center" });
            return;
          }
        }
        // After load so the inlined stylesheet and any seller scripts have laid the page out —
        // scrolling earlier would center on coordinates that then shift.
        window.addEventListener("load", function () { requestAnimationFrame(scrollToChange); });
      })();
    </script>
  HTML

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
    # Injected into the sandboxed landing document at serve time (never authored
    # by the seller) so plain store links work without any seller HTML changes.
    # Clicking a link inside the sandboxed iframe would otherwise navigate the
    # IFRAME itself: the destination page then renders on the opaque origin,
    # where cookies and storage are unavailable, so checkout hangs or the page
    # fails to render entirely. The sandbox deliberately omits
    # allow-top-navigation (and the sanitizer strips target="_top"), so the only
    # safe way out is this bridge: intercept clicks on the store's own links and
    # ask the trusted parent wrapper to navigate the top-level window instead.
    # The parent re-validates the URL against the same hostname allowlist — the
    # iframe content is untrusted, so nothing here is load-bearing for security.
    # Links to foreign hosts and target="_blank" links keep their default
    # behavior.
    def custom_html_navigation_bridge_script(allowed_hostnames:)
      hostnames_json = ERB::Util.json_escape(allowed_hostnames.to_json)
      <<~HTML
        <script data-cfasync="false" data-gumroad-navigation-bridge>
          (function () {
            var STORE_HOSTNAMES = #{hostnames_json};
            document.addEventListener("click", function (e) {
              // Only plain left-clicks: modified clicks (new tab, etc.) keep
              // the browser's default handling.
              if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
              // Viewed directly (not framed) there is no trusted parent to ask,
              // so leave the click alone.
              if (window.parent === window) return;
              var link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
              if (!link) return;
              var target = (link.getAttribute("target") || "").toLowerCase();
              if (target && target !== "_self") return;
              if (link.hasAttribute("download")) return;
              var url;
              try { url = new URL(link.getAttribute("href"), document.baseURI); } catch (_err) { return; }
              if (url.protocol !== "https:" && url.protocol !== "http:") return;
              if (STORE_HOSTNAMES.indexOf(url.hostname) === -1) return;
              // Same-page fragment links should scroll within the iframe, not
              // reload the profile at the top level.
              var here = new URL(document.baseURI);
              if (url.hash && url.pathname === here.pathname && url.search === here.search && url.hostname === here.hostname) return;
              e.preventDefault();
              parent.postMessage({ type: "gumroad:navigate", url: url.href }, "*");
            }, true);
          })();
        </script>
      HTML
    end

    def render_landing_version(visible:, page:)
      render json: { present: visible, version: visible ? page&.updated_at&.to_i : nil }
    end

    # The full sandboxed document for a profile custom-HTML page. Shared by the live
    # /landing/embed endpoint (UsersController) and the agent's proposed-change preview
    # (Api::Internal::AgentCustomHtmlPreviewsController) so a preview can never drift from what
    # actually ships. `meta_csp` embeds CUSTOM_HTML_META_CSP for delivery paths that have no
    # response headers to carry the real CSP (iframe srcdoc). `scroll_to_change` adds the
    # preview-only script that jumps to the PREVIEW_CHANGED_MARKER comment, so an edit further
    # down the page opens in view instead of hiding below the fold.
    def profile_custom_html_document(custom_html, data_json: "{}", live_fields: false, navigation_bridge: "", meta_csp: false, scroll_to_change: false)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{meta_csp ? %(<meta http-equiv="Content-Security-Policy" content="#{ERB::Util.h(CUSTOM_HTML_META_CSP)}">) : ""}
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_inline}
          </head>
          <body>
            <script id="gumroad-data" type="application/json">#{data_json}</script>
            #{custom_html}
            #{navigation_bridge}
            #{live_fields ? PROFILE_FIELDS_PREVIEW_SCRIPT : ""}
            #{scroll_to_change ? PREVIEW_SCROLL_TO_CHANGE_SCRIPT : ""}
          </body>
        </html>
      HTML
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
