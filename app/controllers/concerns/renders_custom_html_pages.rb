# frozen_string_literal: true

# Shared machinery for rendering seller-authored custom HTML inside a
# sandboxed, strictly-CSP'd document. Both product landing pages
# (LinksController) and profile landing pages (UsersController) render the
# same opaque-origin iframe content, so the CSP, the storage-shim script, and
# the shared Tailwind stylesheet all live here to stay in lockstep — a drift
# between the two surfaces would be a security regression, not a cosmetic one.
module RendersCustomHtmlPages
  extend ActiveSupport::Concern

  PAGE_ASSET_HOSTS = [CDN_S3_PROXY_HOST, PUBLIC_STORAGE_CDN_S3_PROXY_HOST].compact.uniq.join(" ")

  # The kitchen-sink Tailwind build these pages rely on is ~4.9 MB, so it's
  # served as a fingerprinted file from the shared asset host (the same S3 +
  # CDN that serves the app's compiled JS/CSS) instead of being inlined into
  # every response. The host must be allowed in style-src explicitly: this
  # document's CSP has no 'self' anywhere, so without this entry the
  # stylesheet <link> would be blocked.
  PAGES_TAILWIND_ASSET_HOST = "#{PROTOCOL}://#{ASSET_DOMAIN}"

  CUSTOM_HTML_CSP = [
    # Sandbox the response itself, not just the wrapper's iframe attribute.
    # A visitor can navigate straight to the /landing/embed endpoint (top-level,
    # not framed), where the iframe sandbox doesn't apply — without this the
    # seller's inline scripts would run on the real subdomain origin. Matches
    # the wrapper iframe's sandbox: scripts + forms + popups, no same-origin/top-nav.
    "sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox",
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

  # Injected into the sandboxed landing document at serve time (never authored
  # by the seller), alongside the navigation bridge below. The sandbox blocks
  # every direct path to the follow endpoint on purpose — the sanitizer strips
  # form actions and the CSP sets connect-src 'none' — so an email-capture
  # form inside the page can't reach gumroad.com on its own. Instead of
  # weakening any of that, this helper asks the trusted parent wrapper to do
  # the follow: it intercepts submits of forms the seller marks with
  # data-gumroad-follow, posts the typed email up as a gumroad:follow message,
  # and reflects the wrapper's success/failure reply back into the page. The
  # parent supplies the seller id from its own context and re-validates
  # everything, so (as with gumroad:navigate) nothing in here is load-bearing
  # for security — a page script could post the same message itself, and
  # script-driven pages are welcome to do exactly that and listen for the
  # gumroad:follow:result window event.
  FOLLOW_BRIDGE_SCRIPT = <<~HTML
    <script data-cfasync="false" data-gumroad-follow-bridge>
      (function () {
        // Viewed directly (not framed) there is no trusted parent to ask,
        // so leave forms alone.
        if (window.parent === window) return;
        // Each submit gets its own request id, and the wrapper echoes the id
        // back in its reply. That correlation is what lets two forms on the
        // same page (hero + footer) be submitted in quick succession without
        // the first reply landing on the second form — a single "active form"
        // slot would be overwritten by the second submit before the first
        // reply arrives.
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
          // Scope the outcome to the form whose submit produced this reply
          // (matched by the echoed request id), so a page with two signup
          // forms (hero + footer) doesn't flip both — even when they're
          // submitted while another request is still in flight. When the
          // message came from a page script instead of a tracked form submit,
          // fall back to every marked form. Message slots inside the matched
          // form win; a page whose slot lives elsewhere (e.g. a paragraph
          // after the form) still gets the document-wide slots.
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
          var nodes = document.querySelectorAll('[data-gumroad-field="' + field + '"]');
          for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
        });
      });
    </script>
  HTML

  module ClassMethods
    # The <head> markup that loads the shared Tailwind build for custom pages.
    # Preferred form is a <link> to the fingerprinted copy on the asset host:
    # the build is ~4.9 MB, and inlining it (the old behavior) made every
    # custom page, product landing, and agent preview response carry the full
    # stylesheet on every view. As an immutable fingerprinted asset it
    # downloads once per browser and that one cached copy serves every
    # seller's pages.
    #
    # Falls back to inlining public/pages-tailwind.css when the manifest is
    # missing (a checkout that hasn't rerun `npm run build:pages-tailwind`
    # since fingerprinting was introduced), and renders nothing when no build
    # exists at all. Memoized per process — both files ship with the deployed
    # artifact and only change on deploy, which restarts the process.
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

    private
      # The manifest maps the logical stylesheet name to its current
      # fingerprinted path (e.g. "assets/pages/pages-tailwind-<sha>.css").
      # Both are written by scripts/build_pages_tailwind.mjs. The path is only
      # trusted if it looks like a build output and the file is actually
      # present on disk — the same tree that gets synced to the asset host —
      # so we never emit a <link> to a stylesheet that wasn't built.
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

    # The trusted-wrapper half of the follow bridge, shared by the profile
    # wrapper (UsersController) and the slugged-page wrapper
    # (UserPagesController) so the two surfaces can't drift. It listens for
    # gumroad:follow messages from the sandboxed landing iframe and POSTs the
    # email to the public follow endpoint. The iframe content is seller-authored
    # and untrusted, so this side is the security boundary:
    # - only messages from the landing frame's opaque origin are accepted;
    # - the seller id comes exclusively from this wrapper's render context —
    #   a seller_id in the message is ignored, so the page can never subscribe
    #   a visitor to someone else's audience;
    # - the email is treated as an opaque string and validated server-side
    #   (the endpoint already serves third-party embed forms and is throttled
    #   by Rack::Attack; follows still require email confirmation).
    # The body is form-encoded, not JSON: the endpoint's per-(IP, seller)
    # Rack::Attack throttle keys on req.params["seller_id"], and Rack only
    # parses form bodies — a JSON body would collapse the throttle into one
    # shared per-IP bucket across all sellers. The CSRF token comes from the
    # placeholder meta tag CsrfTokenInjector fills in after render; with a
    # valid token the visitor's session survives forgery protection, so a
    # signed-in visitor following with their own verified email is confirmed
    # instantly instead of being asked to click a confirmation email.
    # The outcome is posted back into the frame so the page can show a
    # confirmation. targetOrigin must be "*" because the sandboxed frame's
    # origin is opaque — the reply carries only a boolean and a public message.
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
              if (!frame || e.source !== frame.contentWindow || e.origin !== "null") return;
              var d = e.data;
              if (!d || typeof d !== "object" || d.type !== "gumroad:follow") return;
              // The child sends a per-submit request id; echoing it back is
              // what lets the child route each reply to the form that asked,
              // so two forms submitted in quick succession each get their own
              // outcome instead of the first reply landing on the second
              // form. Requests are allowed to overlap — abuse is bounded by
              // the endpoint's Rack::Attack throttle, not by this script.
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

    def render_landing_version(visible:, page:)
      render json: { present: visible, version: visible ? page&.updated_at&.to_i : nil }
    end

    # The full sandboxed document for a profile custom-HTML page. Shared by the live
    # /landing/embed endpoint (UsersController) and the agent's proposed-change preview
    # (Api::Internal::AgentCustomHtmlPreviewsController) so a preview can never drift from what
    # actually ships. Both serve it over HTTP with CUSTOM_HTML_CSP as a response header — never
    # as an iframe srcdoc, which would inherit the embedding dashboard's CSP and block every
    # inline script in the page (a meta CSP tag can't undo that: policies only intersect).
    # `scroll_to_change` adds the preview-only script that jumps to the PREVIEW_CHANGED_MARKER
    # comment, so an edit further down the page opens in view instead of hiding below the fold.
    def profile_custom_html_document(custom_html, data_json: "{}", live_fields: false, navigation_bridge: "", follow_bridge: "", scroll_to_change: false)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_head}
          </head>
          <body>
            <script id="gumroad-data" type="application/json">#{data_json}</script>
            #{custom_html}
            #{navigation_bridge}
            #{follow_bridge}
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
