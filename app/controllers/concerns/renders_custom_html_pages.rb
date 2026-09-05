# frozen_string_literal: true

# Shared machinery for rendering seller-authored custom HTML inside a
# sandboxed, strictly-CSP'd document. Both product landing pages
# (LinksController) and profile landing pages (UsersController) render the
# same opaque-origin iframe content, so the CSP, the storage-shim script, and
# the shared Tailwind stylesheet all live here to stay in lockstep — a drift
# between the two surfaces would be a security regression, not a cosmetic one.
module RendersCustomHtmlPages
  extend ActiveSupport::Concern
  include CurrencyHelper

  PAGE_ASSET_HOSTS = [CDN_S3_PROXY_HOST, PUBLIC_STORAGE_CDN_S3_PROXY_HOST].compact.uniq.join(" ")

  # The kitchen-sink Tailwind build these pages rely on is ~4.9 MB, so it's
  # served as a fingerprinted file from the shared asset host (the same S3 +
  # CDN that serves the app's compiled JS/CSS) instead of being inlined into
  # every response. The host must be allowed in style-src explicitly: this
  # document's CSP has no 'self' anywhere, so without this entry the
  # stylesheet <link> would be blocked.
  PAGES_TAILWIND_ASSET_HOST = "#{PROTOCOL}://#{ASSET_DOMAIN}"

  # Tailwind v3's CDN build. Seller pages (especially agent-generated ones) load
  # it for its runtime `tailwind.config` support, which our v4 build has no
  # equivalent for, so it's allowed by both the sanitizer and the CSP below.
  # Its presence in a page's HTML is what triggers the gradient compatibility
  # shim — see tailwind_v3_gradient_compat_head.
  TAILWIND_V3_CDN_HOST = "cdn.tailwindcss.com"

  # Reachable through the navigate bridge by exact path only (see
  # custom_html_navigation_allowlist_js). Add a path here only if seller-authored
  # HTML sending an anonymous visitor there is harmless: anything that acts on a
  # signed-in account, or that takes a redirect parameter, is not.
  GLOBAL_NAV_PATHS = ["/library", "/checkout"].freeze

  # Hostnames are case-insensitive, and the sanitizer compares them after
  # downcasing (Ai::PageSanitizer.https_host_in?), so a page written as
  # "https://CDN.Tailwindcss.com" passes sanitization and really does load
  # Tailwind v3. The shim trigger below has to match on the same terms or
  # those pages would keep rendering transparent gradients.
  TAILWIND_V3_CDN_HOST_PATTERN = /#{Regexp.escape(TAILWIND_V3_CDN_HOST)}/i

  # Re-registers Tailwind's gradient custom properties with the universal syntax
  # so a v3 page can coexist with our injected v4 build — see
  # tailwind_v3_gradient_compat_head for the mechanism and the ordering rule.
  # The `-position` variables are included because v3 also writes an *empty*
  # value into them (`--tw-gradient-from-position: ;` for an unpositioned stop),
  # which fails v4's <length-percentage> registration the same way.
  TAILWIND_V3_GRADIENT_COMPAT_STYLE = <<~HTML
    <style>
      @property --tw-gradient-from{syntax:"*";inherits:false;initial-value:#0000}
      @property --tw-gradient-via{syntax:"*";inherits:false;initial-value:#0000}
      @property --tw-gradient-to{syntax:"*";inherits:false;initial-value:#0000}
      @property --tw-gradient-from-position{syntax:"*";inherits:false;initial-value:0%}
      @property --tw-gradient-via-position{syntax:"*";inherits:false;initial-value:50%}
      @property --tw-gradient-to-position{syntax:"*";inherits:false;initial-value:100%}
    </style>
  HTML

  # Every custom-page surface must sandbox identically, so they all read this one
  # list rather than repeating the tokens: the wrapper iframes in
  # UsersController/UserPagesController/LinksController and the CSP directive
  # below. Adding a token here widens all four at once; that is the point.
  CUSTOM_HTML_SANDBOX_TOKENS = %w[
    allow-scripts
    allow-forms
    allow-popups
    allow-popups-to-escape-sandbox
  ].freeze

  # This frame renders seller-supplied markup, so widening it to any of these is
  # a buyer-safety decision and a spec fails if one appears. allow-downloads is
  # here by decision: it would let a page hand a visitor a file from any host
  # under the seller's own subdomain. The cost is that a download link does
  # nothing and the browser says nothing, so the docs have to carry that limit.
  CUSTOM_HTML_SANDBOX_FORBIDDEN_TOKENS = %w[
    allow-downloads
    allow-downloads-without-user-activation
    allow-same-origin
    allow-top-navigation
    allow-top-navigation-by-user-activation
  ].freeze

  CUSTOM_HTML_SANDBOX = CUSTOM_HTML_SANDBOX_TOKENS.join(" ").freeze

  CUSTOM_HTML_CSP = [
    # Sandbox the response itself, not just the wrapper's iframe attribute.
    # A visitor can navigate straight to the /landing/embed endpoint (top-level,
    # not framed), where the iframe sandbox doesn't apply — without this the
    # seller's inline scripts would run on the real subdomain origin.
    "sandbox #{CUSTOM_HTML_SANDBOX}",
    "default-src 'none'",
    "script-src 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com",
    "style-src 'unsafe-inline' #{PAGES_TAILWIND_ASSET_HOST} https://cdn.tailwindcss.com https://fonts.googleapis.com https://fonts.bunny.net",
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

  # Injected at serve time, never seller-authored. The sandbox blocks every
  # direct path to the follow endpoint (sanitizer strips form actions, CSP sets
  # connect-src 'none'), so instead of widening it, submits of
  # data-gumroad-follow forms are handed up as gumroad:follow messages and the
  # wrapper's reply is reflected back. The parent supplies the seller id and
  # re-validates, so nothing here is load-bearing for security — a page script
  # may post the same message and listen for gumroad:follow:result.
  FOLLOW_BRIDGE_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-follow-bridge>
      (function () {
        // Viewed directly (not framed) there is no trusted parent to ask,
        // so leave forms alone.
        if (window.parent === window) return;
        // Per-submit request id, echoed back by the wrapper: a single "active
        // form" slot would be overwritten by a second submit before the first
        // reply arrived, landing that reply on the wrong form.
        var pendingForms = {};
        var nextRequestId = 0;
        document.addEventListener("submit", function (e) {
          var form = e.target && e.target.closest ? e.target.closest("form[data-gumroad-follow]") : null;
          if (!form || e.defaultPrevented) return;
          e.preventDefault();
          // Prefer the real email input over anything else named "email" —
          // pages commonly hide a honeypot text field with that name, and a
          // comma-joined selector would return whichever comes first in the
          // DOM.
          var input = form.querySelector('input[type="email"]') || form.querySelector('input[name="email"]');
          var email = input ? String(input.value || "").trim() : "";
          nextRequestId += 1;
          var requestId = "gumroad-follow-" + nextRequestId;
          pendingForms[requestId] = form;
          parent.postMessage({ type: "gumroad:follow", email: email, requestId: requestId }, "*");
        }, true);
        window.addEventListener("message", function (e) {
          // Only the parent wrapper's reply drives the confirmation UI —
          // nested iframes (e.g. embedded video players) can't spoof it.
          if (e.source !== window.parent) return;
          var d = e.data;
          if (!d || typeof d !== "object" || d.type !== "gumroad:follow:result") return;
          var success = d.success === true;
          var message = typeof d.message === "string" ? d.message : "";
          // Untracked request ids come from page scripts posting the message
          // themselves; those fall back to every marked form. Slots inside the
          // matched form win, but a page whose slot lives elsewhere (e.g. a
          // paragraph after the form) still gets the document-wide slots.
          var requestId = typeof d.requestId === "string" ? d.requestId : null;
          var matchedForm = requestId && pendingForms[requestId] ? pendingForms[requestId] : null;
          if (requestId) delete pendingForms[requestId];
          var forms = matchedForm ? [matchedForm] : document.querySelectorAll("form[data-gumroad-follow]");
          for (var i = 0; i < forms.length; i++) {
            forms[i].setAttribute("data-gumroad-follow-state", success ? "success" : "error");
          }
          var slots = matchedForm ? matchedForm.querySelectorAll("[data-gumroad-follow-message]") : [];
          if (!slots.length) slots = document.querySelectorAll("[data-gumroad-follow-message]");
          for (var j = 0; j < slots.length; j++) {
            slots[j].textContent = message;
          }
          // For pages that manage their own UI (popups etc.) instead of
          // using the declarative hooks above.
          try {
            window.dispatchEvent(new CustomEvent("gumroad:follow:result", { detail: { success: success, message: message } }));
          } catch (_err) {}
        });
      })();
    </script>
  HTML

  # Shared by both halves so they cannot disagree about modern color syntax.
  # Alpha follows the slash in modern functions or is the fourth legacy
  # comma-separated channel; a positional match mistakes black's last channel
  # for transparency.
  CANVAS_OPAQUE_FN = <<~JS
    function colorAlpha(color) {
      if (!color || color === "transparent") return 0;
      var body = color.match(/\\(([^)]*)\\)\\s*$/);
      if (!body) return color.indexOf("(") === -1 ? 1 : null;
      var parts = body[1].split("/");
      var alpha = parts.length > 1 ? parts[parts.length - 1] : null;
      if (alpha === null) {
        var channels = body[1].split(",");
        if (channels.length > 3) alpha = channels[3];
      }
      if (alpha === null) return 1;
      var value = parseFloat(alpha);
      if (!isFinite(value)) return null;
      return alpha.indexOf("%") === -1 ? value : value / 100;
    }
    function opaque(color) {
      return colorAlpha(color) === 1;
    }
  JS

  # How often the sandboxed page re-reads its own canvas color as a backstop for
  # rethemes that leave no DOM mutation to observe (see the bridge script). A
  # second is short enough that a wrong tint is not something a visitor sits
  # with, and long enough that the cost stays immeasurable on a quiet page.
  BACKGROUND_POLL_INTERVAL_MS = 1000

  # Report only flat, opaque canvas paint; mirroring translucent paint under
  # the iframe would composite it twice.
  BACKGROUND_BRIDGE_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-background-bridge>
      (function () {
        // Viewed directly (not framed) there is no wrapper to color.
        if (window.parent === window) return;
        #{CANVAS_OPAQUE_FN}
        function flatRootPaint(style) {
          return style.opacity === "1" &&
            style.filter === "none" &&
            style.clipPath === "none" &&
            style.maskImage === "none" &&
            (!style.webkitMaskImage || style.webkitMaskImage === "none") &&
            (!style.maskBorderSource || style.maskBorderSource === "none") &&
            (!style.webkitMaskBoxImage || style.webkitMaskBoxImage === "none") &&
            style.mixBlendMode === "normal" &&
            style.display !== "none";
        }
        function establishesContainment(style) {
          return style.contain !== "none" ||
            (style.contentVisibility && style.contentVisibility !== "visible") ||
            (style.containerType && style.containerType !== "normal");
        }
        function paint(color, colorScheme) {
          return { color: color, colorScheme: colorScheme };
        }
        function schemeBackplate(style) {
          if (!style.colorScheme || style.colorScheme === "normal") return paint(null, null);
          // The trusted wrapper resolves Canvas. Probing here would alter the
          // seller's DOM, including :last-child selectors.
          return paint(null, style.colorScheme);
        }
        function canvasPaint() {
          var rootStyle = window.getComputedStyle(document.documentElement);
          if (!flatRootPaint(rootStyle)) return paint(null, null);
          var root = rootStyle.backgroundColor;
          var rootAlpha = colorAlpha(root);
          if (rootStyle.backgroundImage !== "none") return paint(null, null);
          if (rootAlpha === 1) return paint(root, null);
          if (rootAlpha !== 0 || !document.body) return paint(null, null);
          var bodyStyle = window.getComputedStyle(document.body);
          if (
            bodyStyle.display === "none" ||
            establishesContainment(rootStyle) ||
            establishesContainment(bodyStyle)
          ) return schemeBackplate(rootStyle);
          var body = bodyStyle.backgroundColor;
          if (bodyStyle.backgroundImage !== "none") return paint(null, null);
          if (opaque(body)) return paint(body, null);
          if (colorAlpha(body) !== 0) return paint(null, null);
          return schemeBackplate(rootStyle);
        }
        var reportedColor = null;
        var reportedColorScheme = null;
        var hasReported = false;
        function report(force) {
          var current = canvasPaint();
          if (
            !force &&
            hasReported &&
            current.color === reportedColor &&
            current.colorScheme === reportedColorScheme
          ) return;
          reportedColor = current.color;
          reportedColorScheme = current.colorScheme;
          hasReported = true;
          // The first null matters after an iframe reload: its wrapper may
          // still hold the previous document's tint.
          parent.postMessage({
            type: "gumroad:background",
            color: current.color,
            colorScheme: current.colorScheme
          }, "*");
        }
        window.addEventListener("message", function (e) {
          var d = e.data;
          if (e.source === parent && d && d.type === "gumroad:background:request") report(true);
        });
        var queued = false;
        var queuedForce = false;
        function queueReport(force) {
          if (force === true) queuedForce = true;
          if (queued) return;
          queued = true;
          requestAnimationFrame(function () {
            var shouldForce = queuedForce;
            queued = false;
            queuedForce = false;
            report(shouldForce);
          });
        }
        // Ignore ordinary DOM churn; only selectors and stylesheets can move
        // the canvas color.
        function stylesheetNode(node) {
          var name = node && node.localName;
          return name === "style" || name === "link";
        }
        // A link repaints after insertion, when its own load event fires.
        function watchStylesheetLoad(node) {
          if (node && node.localName === "link") node.addEventListener("load", queueReport);
        }
        function eachStylesheet(node, fn) {
          if (!node) return;
          if (stylesheetNode(node)) fn(node);
          if (!node.querySelectorAll) return;
          var found = node.querySelectorAll("style,link");
          for (var i = 0; i < found.length; i++) fn(found[i]);
        }
        function affectsCanvas(records) {
          var affects = false;
          for (var i = 0; i < records.length; i++) {
            var record = records[i];
            if (record.type === "attributes") {
              if (
                record.target === document.documentElement ||
                record.target === document.body ||
                stylesheetNode(record.target)
              ) affects = true;
              // href swapped on a <link> that is already in the document — the
              // new sheet lands late too.
              if (stylesheetNode(record.target)) watchStylesheetLoad(record.target);
            }
            if (stylesheetNode(record.target)) affects = true;
            if (stylesheetNode(record.target.parentNode)) affects = true;
            for (var j = 0; j < record.addedNodes.length; j++) {
              eachStylesheet(record.addedNodes[j], function (sheet) {
                affects = true;
                watchStylesheetLoad(sheet);
              });
            }
            for (var k = 0; k < record.removedNodes.length; k++) {
              eachStylesheet(record.removedNodes[k], function () { affects = true; });
            }
          }
          return affects;
        }
        report();
        // After load the stylesheet and any seller scripts have applied, so
        // this is the first reading that reflects the finished page.
        window.addEventListener("load", queueReport);
        try {
          new MutationObserver(function (records) {
            if (affectsCanvas(records)) queueReport();
          }).observe(document.documentElement, {
            attributes: true,
            childList: true,
            characterData: true,
            subtree: true
          });
        } catch (_err) {}
        try {
          window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
            // The declared scheme can stay "dark light" while Canvas changes.
            queueReport(true);
          });
        } catch (_err) {}
        // CSSOM writes emit no mutation, so poll a clean style tree as a backstop.
        try {
          setInterval(function () {
            if (!document.hidden) queueReport();
          }, #{BACKGROUND_POLL_INTERVAL_MS});
          document.addEventListener("visibilitychange", queueReport);
        } catch (_err) {}
      })();
    </script>
  HTML

  # Injected at serve time, never seller-authored. The gumroad-data payload
  # carries at most Pages::ProfileData::MAX_ITEMS products and the sandbox blocks
  # fetching the rest, so window.gumroadProducts.request({offset, limit}) asks the
  # wrapper for the next slice, correlated by request id like the follow bridge.
  # Not load-bearing for security — a page script may post gumroad:products
  # itself and listen for gumroad:products:result.
  PRODUCTS_BRIDGE_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-products-bridge>
      (function () {
        // Viewed directly (not framed) there is no trusted parent to ask.
        if (window.parent === window) return;
        var pendingRequests = {};
        var nextRequestId = 0;
        // Minted once per document (this script re-runs on every navigation), so a reply meant
        // for whatever document previously occupied the frame — the wrapper's WindowProxy check
        // can't tell them apart, since it's navigation-stable — can't resolve this document's
        // promises even if the request id was reused.
        var documentToken = Math.random().toString(36).slice(2) + Date.now().toString(36);
        function request(options) {
          options = options || {};
          nextRequestId += 1;
          var requestId = "gumroad-products-" + nextRequestId;
          var promise = new Promise(function (resolve) {
            pendingRequests[requestId] = resolve;
          });
          parent.postMessage({
            type: "gumroad:products",
            offset: options.offset,
            limit: options.limit,
            requestId: requestId,
            documentToken: documentToken
          }, "*");
          return promise;
        }
        try { window.gumroadProducts = { request: request }; } catch (_err) {}
        window.addEventListener("message", function (e) {
          // Only the parent wrapper's reply resolves a request — nested
          // iframes (e.g. embedded video players) can't spoof it.
          if (e.source !== window.parent) return;
          var d = e.data;
          if (!d || typeof d !== "object" || d.type !== "gumroad:products:result") return;
          if (d.documentToken !== documentToken) return;
          var requestId = typeof d.requestId === "string" ? d.requestId : null;
          var resolve = requestId && pendingRequests[requestId] ? pendingRequests[requestId] : null;
          if (requestId) delete pendingRequests[requestId];
          var detail = {
            success: d.success === true,
            products: Array.isArray(d.products) ? d.products : [],
            productsTotal: typeof d.productsTotal === "number" ? d.productsTotal : null,
            prices: d.prices && typeof d.prices === "object" && !Array.isArray(d.prices) ? d.prices : {},
            offset: typeof d.offset === "number" ? d.offset : null,
            limit: typeof d.limit === "number" ? d.limit : null,
            requestId: requestId
          };
          if (resolve) resolve(detail);
          // For pages that posted their own message instead of going through
          // window.gumroadProducts.
          try {
            window.dispatchEvent(new CustomEvent("gumroad:products:result", { detail: detail }));
          } catch (_err) {}
        });
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
        // After load so the Tailwind stylesheet and any seller scripts have laid the page out —
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
          // Product-scoped elements belong to the prices payload; the server-side interpolator
          // never answers them with profile fields, so the preview must not either.
          var nodes = document.querySelectorAll('[data-gumroad-field="' + field + '"]:not([data-gumroad-product])');
          for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
        });
      });
    </script>
  HTML

  module ClassMethods
    # Shared Tailwind for custom pages. Prefer a <link> to the fingerprinted
    # asset (~4.9 MB; inlining put the full sheet on every page and preview).
    # Falls back to inlining public/pages-tailwind.css when the manifest is
    # missing, else empty. Memoized per process — files only change on deploy.
    def pages_tailwind_head
      return @pages_tailwind_head if @pages_tailwind_head

      if (asset_path = pages_tailwind_asset_path)
        @pages_tailwind_head = %(<link rel="stylesheet" href="#{PAGES_TAILWIND_ASSET_HOST}/#{asset_path}">)
      else
        css_path = Rails.root.join("public/pages-tailwind.css")
        return "" unless File.exist?(css_path)

        @pages_tailwind_head = "<style>#{File.read(css_path)}</style>"
      end
    end

    # A page loading Tailwind v3 from the CDN ends up with two Tailwind majors on
    # one document (we always inject v4, see pages_tailwind_head), and they
    # disagree about what a gradient variable holds. v4 registers it as strictly a
    # <color>, and @property registration is document-global:
    #   @property --tw-gradient-from{syntax:"<color>";initial-value:#0000}
    # v3 writes a color AND a position into that same variable:
    #   .from-navy-700{--tw-gradient-from:#173a70 var(--tw-gradient-from-position)}
    # "#173a70 0%" is not a <color>, so the browser silently substitutes the
    # registered initial-value #0000 and every v3 gradient renders transparent.
    #
    # Re-registering with the universal syntax "*" accepts v3's value. It must be
    # emitted AFTER our v4 stylesheet — for duplicate @property rules the last
    # registration wins — and only for pages that load the v3 CDN, so v4-only
    # pages keep v4's exact registrations.
    def tailwind_v3_gradient_compat_head(custom_html)
      return "" unless custom_html.to_s.match?(TAILWIND_V3_CDN_HOST_PATTERN)

      TAILWIND_V3_GRADIENT_COMPAT_STYLE
    end

    private
      # Logical name → fingerprinted path from scripts/build_pages_tailwind.mjs.
      # Only emit a <link> if the path looks like a build output and the file
      # exists on disk (the tree synced to the asset host).
      def pages_tailwind_asset_path
        manifest_path = Rails.root.join("public/pages-tailwind-manifest.json")
        return nil unless File.exist?(manifest_path)

        asset_path = JSON.parse(File.read(manifest_path))["pages-tailwind.css"]
        return nil unless asset_path.is_a?(String) && asset_path.match?(%r{\Aassets/pages/pages-tailwind-\h+\.css\z})
        return nil unless File.exist?(Rails.root.join("public", asset_path))

        asset_path
      rescue JSON::ParserError
        nil
      end
  end

  private
    # gumroadNavigationTarget(url, storeHostnames) — iframe interceptor and
    # trusted wrapper must agree or a link is dropped or intercepted then refused.
    # GLOBAL_NAV_PATHS live on a host no seller controls, so they match on exact
    # path (query/fragment dropped), never via the hostname allowlist.
    def custom_html_navigation_allowlist_js
      <<~JS
        var GUMROAD_NAV_HOSTS = #{ERB::Util.json_escape(VALID_REQUEST_HOSTS.to_json)};
        var GUMROAD_NAV_PATHS = #{ERB::Util.json_escape(GLOBAL_NAV_PATHS.to_json)};
        function gumroadNavigationTarget(url, storeHostnames) {
          if (storeHostnames.indexOf(url.hostname) !== -1) return url.href;
          if (GUMROAD_NAV_HOSTS.indexOf(url.hostname) === -1) return null;
          var path = url.pathname.replace(/\\/+$/, "");
          if (GUMROAD_NAV_PATHS.indexOf(path) === -1) return null;
          return url.origin + path;
        }
      JS
    end

    # Serve-time so store links work without seller HTML changes. A click would
    # otherwise navigate the iframe onto the opaque origin (no cookies/storage).
    # Sandbox omits allow-top-navigation and the sanitizer strips target="_top",
    # so we hand store links to the parent, which re-validates the same allowlist.
    # Foreign hosts and target="_blank" keep default behavior.
    def custom_html_navigation_bridge_script(allowed_hostnames:)
      hostnames_json = ERB::Util.json_escape(allowed_hostnames.to_json)
      <<~HTML
        <script data-cfasync="false" data-gumroad-navigation-bridge>
          (function () {
            var STORE_HOSTNAMES = #{hostnames_json};
            #{custom_html_navigation_allowlist_js.indent(4).strip}
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
              var destination = gumroadNavigationTarget(url, STORE_HOSTNAMES);
              if (destination === null) return;
              // Same-page fragment links should scroll within the iframe, not
              // reload the profile at the top level.
              var here = new URL(document.baseURI);
              if (url.hash && url.pathname === here.pathname && url.search === here.search && url.hostname === here.hostname) return;
              e.preventDefault();
              parent.postMessage({ type: "gumroad:navigate", url: destination }, "*");
            }, true);
          })();
        </script>
      HTML
    end

    # Trusted-wrapper half of the follow bridge (UsersController and
    # UserPagesController). Untrusted iframe: seller id comes only from this
    # render context (a seller_id in the message is ignored). Body must be
    # form-encoded — Rack::Attack keys on req.params["seller_id"] and Rack only
    # parses form bodies, so JSON would collapse the throttle to one per-IP
    # bucket. CSRF token is the placeholder meta CsrfTokenInjector fills after
    # render. targetOrigin is "*" because the frame origin is opaque; the reply
    # is only a boolean and a public message.
    def custom_html_follow_wrapper_script(seller_external_id:, nonce:)
      seller_id_json = ERB::Util.json_escape(seller_external_id.to_json)
      endpoint_json = ERB::Util.json_escape(follow_user_from_embed_form_path.to_json)
      <<~HTML
        <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false" data-gumroad-follow-wrapper>
          (function () {
            var frame = document.getElementById("gumroad-landing-frame");
            var SELLER_ID = #{seller_id_json};
            var ENDPOINT = #{endpoint_json};
            var GENERIC_ERROR = "Something went wrong. Please try again.";
            window.addEventListener("message", function (e) {
              if (!frame || e.source !== frame.contentWindow) return;
              var d = e.data;
              if (!d || typeof d !== "object" || d.type !== "gumroad:follow") return;
              // Echoed back so the child can route each reply to the form that
              // asked. Requests may overlap — abuse is bounded by the endpoint's
              // Rack::Attack throttle, not by this script.
              var requestId = typeof d.requestId === "string" ? d.requestId : null;
              function reply(success, message) {
                frame.contentWindow.postMessage({ type: "gumroad:follow:result", success: success, message: message, requestId: requestId }, "*");
              }
              var email = typeof d.email === "string" ? d.email.trim() : "";
              // Real validation happens server-side; only skip the request
              // when there is nothing to validate.
              if (!email) {
                reply(false, "Please enter a valid email address.");
                return;
              }
              var token = document.querySelector('meta[name="csrf-token"]');
              var body = new URLSearchParams();
              body.set("seller_id", SELLER_ID);
              body.set("email", email);
              fetch(ENDPOINT, {
                method: "POST",
                headers: { "Accept": "application/json", "X-CSRF-Token": token ? token.content : "" },
                credentials: "same-origin",
                body: body
              })
                .then(function (r) { return r.json(); })
                .then(function (data) { reply(data && data.success === true, data && typeof data.message === "string" ? data.message : GENERIC_ERROR); })
                // Network failure, or a non-JSON body such as a Rack::Attack
                // 429 while throttled.
                .catch(function () { reply(false, GENERIC_ERROR); });
            });
          })();
        </script>
      HTML
    end

    # Trusted-wrapper half of the products bridge (gumroad-private#1691).
    # Untrusted iframe: only e.source === landing frame; endpoint URL is baked
    # here so the page cannot pick another seller; offset/limit are clamped to
    # MAX_ITEMS here and re-validated on the server. Reply echoes requestId so
    # in-flight requests don't cross. targetOrigin is "*" (opaque frame origin);
    # the reply is the public catalogue data page 1 already exposes.
    def custom_html_products_wrapper_script(products_src:, nonce:)
      endpoint_json = ERB::Util.json_escape(products_src.to_json)
      <<~HTML
        <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false" data-gumroad-products-wrapper>
          (function () {
            var frame = document.getElementById("gumroad-landing-frame");
            var ENDPOINT = #{endpoint_json};
            var MAX_ITEMS = #{Pages::ProfileData::MAX_ITEMS};
            window.addEventListener("message", function (e) {
              if (!frame || e.source !== frame.contentWindow) return;
              var d = e.data;
              if (!d || typeof d !== "object" || d.type !== "gumroad:products") return;
              var requestId = typeof d.requestId === "string" ? d.requestId : null;
              function reply(payload) {
                payload.type = "gumroad:products:result";
                payload.requestId = requestId;
                frame.contentWindow.postMessage(payload, "*");
              }
              var offset = d.offset;
              var limit = d.limit;
              if (typeof offset !== "number" || !isFinite(offset) || Math.floor(offset) !== offset || offset < 0) {
                reply({ success: false });
                return;
              }
              if (limit === undefined || limit === null) limit = MAX_ITEMS;
              if (typeof limit !== "number" || !isFinite(limit) || Math.floor(limit) !== limit || limit < 1) {
                reply({ success: false });
                return;
              }
              if (limit > MAX_ITEMS) limit = MAX_ITEMS;
              fetch(ENDPOINT + "?offset=" + offset + "&limit=" + limit, {
                headers: { "Accept": "application/json" },
                credentials: "same-origin"
              })
                .then(function (r) { return r.ok ? r.json() : null; })
                .then(function (data) {
                  if (!data || data.success !== true) { reply({ success: false }); return; }
                  reply({
                    success: true,
                    products: data.products,
                    productsTotal: data.products_total,
                    prices: data.prices,
                    offset: data.offset,
                    limit: data.limit
                  });
                })
                // Network failure, or a non-JSON body such as a Rack::Attack
                // 429 while throttled.
                .catch(function () { reply({ success: false }); });
            });
          })();
        </script>
      HTML
    end

    # Resolve the untrusted report in this document before painting the wrapper
    # and theme-color. A detached probe would accept unresolved var()/keywords;
    # backgroundColor cannot fetch a URL.
    def custom_html_background_wrapper_script(nonce:)
      <<~HTML
        <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false" data-gumroad-background-wrapper>
          (function () {
            var frame = document.getElementById("gumroad-landing-frame");
            var meta = null;
            #{CANVAS_OPAQUE_FN}
            // Must be IN the document: computed values resolve against the
            // element's context, and a detached node has none.
            var probe = document.createElement("div");
            probe.setAttribute("aria-hidden", "true");
            probe.style.display = "none";
            var probeAttached = false;
            // A computed color is well under this; the cap just stops a hostile
            // child from making us parse megabyte strings in a loop.
            var MAX_VALUE_LENGTH = 128;
            function resolve(value, colorScheme) {
              if (!probeAttached) {
                document.body.appendChild(probe);
                probeAttached = true;
              }
              probe.style.colorScheme = "";
              probe.style.backgroundColor = "";
              if (colorScheme !== null) {
                probe.style.colorScheme = colorScheme;
                var computedScheme = window.getComputedStyle(probe).colorScheme;
                if (!probe.style.colorScheme || !computedScheme || computedScheme === "normal") return null;
                value = "Canvas";
              }
              // Must stay `backgroundColor` — a color property cannot fetch, so
              // `var(--x, url(https://evil.example/pixel))` never dereferences.
              // The `background` shorthand or `backgroundImage` would fire it.
              probe.style.backgroundColor = value;
              var computed = window.getComputedStyle(probe).backgroundColor;
              if (!opaque(computed)) return null;
              return computed;
            }
            function clear() {
              document.documentElement.style.backgroundColor = "";
              if (meta) {
                meta.parentNode.removeChild(meta);
                meta = null;
              }
            }
            frame.addEventListener("load", function () {
              clear();
              frame.contentWindow.postMessage({ type: "gumroad:background:request" }, "*");
            });
            window.addEventListener("message", function (e) {
              if (!frame || e.source !== frame.contentWindow) return;
              var d = e.data;
              if (!d || typeof d !== "object" || d.type !== "gumroad:background") return;
              var colorScheme = d.colorScheme == null ? null : d.colorScheme;
              // The page went transparent after having a color: drop the tint
              // rather than leaving the previous theme painted under it.
              if (d.color === null && colorScheme === null) return clear();
              var color;
              if (colorScheme !== null) {
                if (
                  d.color !== null ||
                  typeof colorScheme !== "string" ||
                  colorScheme.length > MAX_VALUE_LENGTH
                ) return;
                color = resolve("", colorScheme);
              } else {
                if (typeof d.color !== "string" || d.color.length > MAX_VALUE_LENGTH) return;
                color = resolve(d.color, null);
              }
              // An unresolvable value is refused outright — it is not evidence
              // that the page has no background, so whatever is applied stays.
              if (!color) return;
              document.documentElement.style.backgroundColor = color;
              if (!meta) {
                meta = document.createElement("meta");
                meta.setAttribute("name", "theme-color");
                document.head.appendChild(meta);
              }
              meta.setAttribute("content", color);
            });
          })();
        </script>
      HTML
    end

    def render_landing_version(visible:, page:)
      render json: { present: visible, version: visible ? page&.updated_at&.to_i : nil }
    end

    # One catalogue slice for the gumroad:products bridge (gumroad-private#1691). Shared by the
    # public endpoint (UsersController#landing_products) and the editor preview's responder
    # (PagesController#products) so a page paginates identically in both, and renders the
    # JSON itself because the two differ only in how they resolve and authorize the seller.
    # Everything returned is data the page 1 payload already exposes.
    def render_custom_html_products_slice(seller)
      offset = Integer(params[:offset], exception: false)
      limit = Integer(params[:limit], exception: false)
      return render json: { success: false }, status: :bad_request if offset.nil? || offset.negative? || limit.nil? || limit < 1

      limit = [limit, Pages::ProfileData::MAX_ITEMS].min
      # Rejected against the count BEFORE paging: MySQL walks and discards every row preceding a
      # large OFFSET, so an unbounded one is a cheap way to make this endpoint expensive from
      # outside, and each distinct offset would also take its own cache entry.
      return render json: { success: false }, status: :bad_request if offset > Pages::ProfileData.products_total(seller)

      page = Pages::ProfileData.products_page(seller, offset:, limit:)
      # The prices half is uncached and derived from the visitor's IP, so this response must
      # never be shared — same rule as landing_iframe_content. And same as there, the build is
      # skipped for pages that reference no price: they cannot consume it.
      response.cache_control.replace(private: true, no_store: true)
      prices = Pages::ProductPrices.referenced_in?(seller.custom_html) ? Pages::ProductPrices.build(seller, ip: request.remote_ip, preferred_currency: buyer_currency_preference(request), offset:, limit:) : {}
      render json: {
        success: true,
        offset:,
        limit:,
        products: page[:products],
        products_total: page[:products_total],
        prices:,
      }
    end

    # Sandboxed document for a profile custom-HTML page. Shared by live
    # /landing/embed and the agent preview so they cannot drift. Served over HTTP
    # with CUSTOM_HTML_CSP — never iframe srcdoc (srcdoc inherits the dashboard
    # CSP; a meta tag cannot loosen it). `scroll_to_change` jumps to
    # PREVIEW_CHANGED_MARKER so an edit further down the page opens in view.
    def profile_custom_html_document(custom_html, data_json: "{}", prices_json: nil, live_fields: false, navigation_bridge: "", follow_bridge: "", products_bridge: "", scroll_to_change: false)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_head}
            #{self.class.tailwind_v3_gradient_compat_head(custom_html)}
          </head>
          <body>
            <script id="gumroad-data" type="application/json">#{data_json}</script>
            #{prices_json.present? ? %(<script id="gumroad-prices" type="application/json">#{prices_json}</script>) : ""}
            #{custom_html}
            #{navigation_bridge}
            #{follow_bridge}
            #{products_bridge}
            #{BACKGROUND_BRIDGE_SCRIPT}
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
