import { createInertiaApp } from "@inertiajs/react";
import { createElement } from "react";
import { createRoot } from "react-dom/client";

import AppWrapper from "../inertia/app_wrapper.tsx";

async function resolvePageComponent(name) {
  try {
    const module = await import(`../pages/${name}.tsx`);
    return module.default;
  } catch {
    try {
      const module = await import(`../pages/${name}.jsx`);
      return module.default;
    } catch {
      throw new Error(`Page component not found: ${name}`);
    }
  }
}

createInertiaApp({
  progress: false,
  resolve: (name) => resolvePageComponent(name),
  setup({ el, App, props }) {
    if (!el) return;

    const global = props.initialPage.props;

    const root = createRoot(el);
    root.render(createElement(AppWrapper, { global }, createElement(App, props)));
  },
});
