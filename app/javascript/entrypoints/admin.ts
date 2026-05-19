import { createInertiaApp } from "@inertiajs/react";
import React, { createElement } from "react";
import { createRoot } from "react-dom/client";

import AdminAppWrapper, { GlobalProps } from "../inertia/admin_app_wrapper";
import Layout from "../layouts/Admin";

const AdminLayout = (page: React.ReactNode) => React.createElement(Layout, { children: page });

type PageComponent = React.ComponentType & { layout?: (page: React.ReactNode) => React.ReactElement };

const isPageComponent = (value: unknown): value is PageComponent => typeof value === "function";

const tsxPages = import.meta.glob('../pages/**/*.tsx');
const jsxPages = import.meta.glob('../pages/**/*.jsx');

const resolvePageComponent = async (name: string): Promise<PageComponent> => {
  const tsxPath = `../pages/${name}.tsx`;
  const jsxPath = `../pages/${name}.jsx`;

  if (tsxPages[tsxPath]) {
    const page: unknown = await tsxPages[tsxPath]();
    if (page && typeof page === "object" && "default" in page && isPageComponent(page.default)) {
      const component = page.default;
      component.layout = AdminLayout;
      return component;
    }
    throw new Error(`Invalid page component: ${name}`);
  }

  if (jsxPages[jsxPath]) {
    const page: unknown = await jsxPages[jsxPath]();
    if (page && typeof page === "object" && "default" in page && isPageComponent(page.default)) {
      const component = page.default;
      component.layout = AdminLayout;
      return component;
    }
    throw new Error(`Invalid page component: ${name}`);
  }

  throw new Error(`Admin page component not found: ${name}`);
};

void createInertiaApp<GlobalProps>({
  progress: false,
  resolve: (name: string) => resolvePageComponent(name),
  setup({ el, App, props }) {
    const global = props.initialPage.props;

    const root = createRoot(el);
    root.render(createElement(AdminAppWrapper, { global, children: createElement(App, props) }));
  },
  title: (title: string) => (title ? `${title} - Admin` : "Admin"),
});
