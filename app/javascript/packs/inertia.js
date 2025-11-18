import { createInertiaApp, router } from "@inertiajs/react";
import { createElement } from "react";
import { createRoot } from "react-dom/client";

import AppWrapper from "../inertia/app_wrapper.tsx";
import Layout from "../inertia/layout.tsx";

// Configure Inertia to send CSRF token with all requests
router.on("before", (event) => {
  const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
  if (token) {
    event.detail.visit.headers = {
      ...event.detail.visit.headers,
      "X-CSRF-Token": token,
    };
  }
});

async function resolvePageComponent(name) {
  try {
    const module = await import(`../pages/${name}.tsx`);
    const page = module.default;
    page.layout ||= (page) => createElement(Layout, { children: page });
    return page;
  } catch {
    try {
      const module = await import(`../pages/${name}.jsx`);
      const page = module.default;
      page.layout ||= (page) => createElement(Layout, { children: page });
      return page;
    } catch {
      throw new Error(`Page component not found: ${name}`);
    }
  }
}

createInertiaApp({
  progress: false,
  resolve: (name) => resolvePageComponent(name),
  title: (title) => (title ? `${title}` : "Gumroad"),
  setup({ el, App, props }) {
    if (!el) return;

    const global = props.initialPage.props;

    const root = createRoot(el);
    root.render(createElement(AppWrapper, { global }, createElement(App, props)));
  },
});
