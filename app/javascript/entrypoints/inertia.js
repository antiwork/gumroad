import { createInertiaApp, router } from "@inertiajs/react";
import { createElement } from "react";
import { createRoot } from "react-dom/client";

import AppWrapper from "../inertia/app_wrapper.tsx";
import Layout, { PublicLayout, LoggedInUserLayout } from "../inertia/layout.tsx";
import { isUnredirectedDownloadPagePollResponse, warnAboutDroppedPollResponse } from "../utils/inertia_partial_reload";
import { installFileDropNavigationGuard } from "../utils/preventFileDropNavigation";
import { defaults as requestDefaults } from "../utils/request";

// Keep the `request()` util's CSRF token current for Inertia pages. `base_page.ts` only
// sets `requestDefaults.headers` on legacy react-on-rails pages, so without this a `request()`
// POST after a client-side navigation (e.g. right after login) sends a stale/missing token and
// fails CSRF verification. `authenticity_token` is a shared Inertia prop, fresh on every visit.
function syncRequestCsrfToken(token) {
  if (token) requestDefaults.headers = { ...requestDefaults.headers, "X-CSRF-Token": token };
}

// Prevent "Failed to execute 'removeChild' on 'Node'" errors caused by
// browser translation extensions (e.g. Google Translate) relocating DOM nodes.
// See https://github.com/facebook/react/issues/11538
if (typeof Node !== "undefined") {
  const originalRemoveChild = Node.prototype.removeChild;
  Node.prototype.removeChild = function (child) {
    if (child.parentNode !== this) {
      return child;
    }
    return originalRemoveChild.apply(this, arguments);
  };

  const originalInsertBefore = Node.prototype.insertBefore;
  Node.prototype.insertBefore = function (newNode, referenceNode) {
    if (referenceNode && referenceNode.parentNode !== this) {
      return newNode;
    }
    return originalInsertBefore.apply(this, arguments);
  };
}

router.on("start", (event) => {
  if (event.detail.visit.prefetch) return;
  window.__activeRequests = (window.__activeRequests || 0) + 1;
});

router.on("finish", (event) => {
  if (event.detail.visit.prefetch) return;
  window.__activeRequests = Math.max((window.__activeRequests || 1) - 1, 0);
});

// Configure Inertia to send CSRF token with all requests
router.on("before", (event) => {
  const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
  if (token) {
    event.detail.visit.headers = {
      ...event.detail.visit.headers,
      "X-CSRF-Token": token,
    };
  }

  // Track previous route for navigation (only for GET requests)
  const method = event.detail.visit.method?.toLowerCase() || "get";
  if (method === "get" && !event.detail.visit.prefetch) {
    const currentUrl = new URL(window.location.href);
    const newUrl =
      typeof event.detail.visit.url === "string"
        ? new URL(event.detail.visit.url, window.location.origin)
        : event.detail.visit.url;

    if (currentUrl.href !== newUrl.href) {
      sessionStorage.setItem("inertia_previous_route", currentUrl.pathname);
    }
  }
});

router.on("success", (event) => {
  syncRequestCsrfToken(event.detail.page.props.authenticity_token);
});

// Handle non-Inertia responses (e.g., redirects to non-Inertia pages after login)
// This fires AFTER the server responds, so authentication is already complete
router.on("invalid", (event) => {
  event.preventDefault();

  const response = event.detail.response;

  // A buyer-content-page background poll that came back non-Inertia from the URL it asked for
  // is dropped rather than navigated to: those requests happen on a timer while the buyer is
  // using the page, and reloading the same URL re-issues whatever was just intercepted, which
  // destroys a long viewing session (see utils/inertia_partial_reload.ts). Dropping is safe —
  // the poll keeps running and the next successful response refreshes the props. The guard is
  // scoped to exactly the GET polls the server recognizes in
  // `UrlRedirectsController#download_page_polling_request?`, so every other request in the app
  // — forms, searches, and all other `only:` visits — behaves exactly as before. A poll that
  // was genuinely REDIRECTED (expired session, revoked access, inactive membership, expired
  // rental) still navigates, because those land on a different path.
  //
  // Known tradeoff: a few access terminations render a 404 at the SAME url instead of
  // redirecting — a purchase refunded or charged back mid-session, or an installment whose
  // files were deleted (see check_permissions in url_redirects_controller.rb). Those are
  // swallowed too, so the buyer keeps the already-loaded page until they next navigate. That
  // is deliberate: a same-url non-Inertia response is indistinguishable from the transient
  // interception this guard exists to absorb, and the client cannot tell them apart without a
  // server-side signal (a distinct header on terminal states would be the way to fix it).
  // Erring toward keeping the session is the point — no new content is served either way.
  if (isUnredirectedDownloadPagePollResponse(response)) {
    // Dropping is silent from the buyer's side, so leave a console breadcrumb (once per URL) —
    // otherwise a persistent interception looks like nothing but progress that stopped updating.
    warnAboutDroppedPollResponse(response);
    return;
  }

  const redirectedUrl = response.request.responseURL;
  if (redirectedUrl) {
    window.location.href = redirectedUrl;
  }
});

router.on("exception", (event) => {
  // When logging in for a mobile OAuth flow, the redirect chain ends at a custom scheme
  // (gumroadmobile://) that XHR can't follow. Fall back to navigating the browser
  // to the OAuth authorize URL so it can handle the custom scheme redirect natively.
  const next = new URLSearchParams(window.location.search).get("next");
  if (next?.includes("redirect_uri=gumroadmobile")) {
    event.preventDefault();
    window.location.href = next;
  }
});

function assignLayout(page) {
  if (page.publicLayout) {
    page.layout ||= (page) => createElement(PublicLayout, { children: page });
  } else if (page.loggedInUserLayout) {
    page.layout ||= (page) => createElement(LoggedInUserLayout, { children: page });
  } else {
    page.layout ||= (page) => createElement(Layout, { children: page });
  }
  return page;
}

const pages = import.meta.glob("../pages/**/*.tsx");
const jsxPages = import.meta.glob("../pages/**/*.jsx");

async function resolvePageComponent(name) {
  const tsxPath = `../pages/${name}.tsx`;
  const jsxPath = `../pages/${name}.jsx`;

  if (pages[tsxPath]) {
    const module = await pages[tsxPath]();
    return assignLayout(module.default);
  }

  if (jsxPages[jsxPath]) {
    const module = await jsxPages[jsxPath]();
    return assignLayout(module.default);
  }

  throw new Error(`Page component not found: ${name}`);
}

createInertiaApp({
  // Show Inertia's top-of-page progress bar on client-side navigations. This used to be `false`,
  // which meant a tap on a link produced no feedback whatsoever until the next page finished
  // rendering. Some of our page chunks are large (the product editor is a few hundred kilobytes),
  // so on a slow connection a tap that WORKED and a tap that MISSED looked exactly the same for
  // several seconds — sellers reasonably concluded the app was broken and filed support tickets
  // saying clicks "do nothing" (gumroad-private#1343, gumroad-private#1469).
  //
  // `delay: 250` is Inertia's default: navigations that resolve faster than 250ms never draw the
  // bar, so instant transitions (including prefetched sidebar links) still look instant and don't
  // flash. Prefetch requests never show the bar at all — Inertia sets `showProgress: false` on
  // them internally. `showSpinner: false` keeps it to the thin top bar with no corner spinner.
  progress: {
    color: "#ff90e8", // Gumroad pink, legible against both the light and dark page backgrounds.
    delay: 250,
    showSpinner: false,
  },
  resolve: resolvePageComponent,
  title: (title) => title || "Gumroad",
  setup({ el, App, props }) {
    if (!el) return;

    const global = props.initialPage.props;
    syncRequestCsrfToken(global.authenticity_token);

    const root = createRoot(el);
    root.render(createElement(AppWrapper, { global }, createElement(App, props)));
    installFileDropNavigationGuard();
  },
});
