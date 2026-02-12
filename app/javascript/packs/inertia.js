import { createInertiaApp, router } from "@inertiajs/react";
import { createElement } from "react";
import { createRoot } from "react-dom/client";

import AppWrapper from "../inertia/app_wrapper.tsx";
import Layout, { PublicLayout, LoggedInUserLayout } from "../inertia/layout.tsx";

router.on("start", () => {
  window.__activeRequests = (window.__activeRequests || 0) + 1;
});

router.on("finish", () => {
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
  if (method === "get") {
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

// Handle non-Inertia responses (e.g., redirects to non-Inertia pages after login)
// This fires AFTER the server responds, so authentication is already complete
router.on("invalid", (event) => {
  event.preventDefault();

  const response = event.detail.response;

  const redirectedUrl = response.request.responseURL;
  if (redirectedUrl) {
    window.location.href = redirectedUrl;
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

async function resolvePageComponent(name) {
  try {
    const module = await import(`../pages/${name}.tsx`);
    return assignLayout(module.default);
  } catch {
    try {
      const module = await import(`../pages/${name}.jsx`);
      return assignLayout(module.default);
    } catch {
      throw new Error(`Page component not found: ${name}`);
    }
  }
}

createInertiaApp({
  progress: { delay: 100, color: "#FF90E8" },
  resolve: resolvePageComponent,
  title: (title) => title || "Gumroad",
  setup({ el, App, props }) {
    if (!el) return;

    const global = props.initialPage.props;

    const root = createRoot(el);
    root.render(createElement(AppWrapper, { global }, createElement(App, props)));
  },
});
