import { createInertiaApp, router } from "@inertiajs/react";
import React, { createElement } from "react";
import { createRoot } from "react-dom/client";

import AdminAppWrapper, { GlobalProps } from "../inertia/admin_app_wrapper";
import Layout from "../layouts/Admin";

const AdminLayout = (page: React.ReactNode) => React.createElement(Layout, { children: page });

type PageComponent = React.ComponentType & { layout?: (page: React.ReactNode) => React.ReactElement };

const isPageComponent = (value: unknown): value is PageComponent => typeof value === "function";

const resolvePageComponent = async (name: string): Promise<PageComponent> => {
  try {
    const page: unknown = await import(`../pages/${name}.tsx`);
    if (page && typeof page === "object" && "default" in page && isPageComponent(page.default)) {
      const component = page.default;
      component.layout = AdminLayout;
      return component;
    }
    throw new Error(`Invalid page component: ${name}`);
  } catch {
    try {
      const page: unknown = await import(`../pages/${name}.jsx`);
      if (page && typeof page === "object" && "default" in page && isPageComponent(page.default)) {
        const component = page.default;
        component.layout = AdminLayout;
        return component;
      }
      throw new Error(`Invalid page component: ${name}`);
    } catch {
      throw new Error(`Admin page component not found: ${name}`);
    }
  }
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

// Temporary interceptor to trigger full page reloads
// for urls that are not yet migrated to inertia
// then remove this check when they are all migrated
const urlsMigratedtoInertia = [
  Routes.admin_url(),
  Routes.admin_suspend_users_url(),
  Routes.admin_block_email_domains_url(),
  Routes.admin_unblock_email_domains_url(),
  // Routes.admin_refund_queue_url(),
  // Routes.admin_sales_reports_url(),
  // Routes.admin_search_users_url(),
  // Routes.admin_search_purchases_url(),
  // Routes.admin_compliance_guids_url(),
  // Routes.admin_compliance_cards_url(),
  // Routes.admin_user_url(),
  // Routes.admin_product_url(),
  // Add other urls here when they are migrated to inertia
];

interface InertiaBeforeEvent extends Event {
  detail: {
    response?: Response & { url?: string };
    visit: { url: URL };
  };
}

router.on("before", (event: InertiaBeforeEvent) => {
  const url = event.detail.visit.url.toString();
  const hasMigratedToInertia = url && urlsMigratedtoInertia.includes(url);

  if (!hasMigratedToInertia) {
    event.preventDefault();
    const searchParams = new URLSearchParams(event.detail.visit.url.searchParams);
    const uri = new URL(event.detail.visit.url);
    searchParams.forEach((value, key) => {
      uri.searchParams.set(key, value);
    });
    window.location.href = uri.toString();
  }
});
