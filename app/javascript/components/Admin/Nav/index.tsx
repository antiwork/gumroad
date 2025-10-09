import { Link } from "@inertiajs/react";
import * as React from "react";

import { CurrentUser } from "$app/types/user";

import AdminNavFooter from "$app/components/Admin/Nav/Footer";
import { useAppDomain } from "$app/components/DomainSettings";
import { Nav as NavFramework, NavLink, InertiaNavLink } from "$app/components/Nav/Base";

type Props = { title: string; current_user: CurrentUser };

const Nav = ({ title, current_user }: Props) => {
  const routeParams = { host: useAppDomain() };

  return (
    <NavFramework title={title} footer={<AdminNavFooter current_user={current_user} />}>
      <section>
        <InertiaNavLink
          text="Suspend users"
          icon="shield-exclamation"
          href={Routes.admin_suspend_users_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Block emails"
          icon="envelope-fill"
          href={Routes.admin_block_email_domains_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Unblock emails"
          icon="envelope-open-fill"
          href={Routes.admin_unblock_email_domains_url(routeParams)}
          component={Link}
        />
        <NavLink text="Sidekiq" icon="lighting-fill" href={Routes.admin_sidekiq_web_url(routeParams)} />
        <NavLink text="Features" icon="solid-flag" href={Routes.admin_flipper_ui_url(routeParams)} />
        <InertiaNavLink
          text="Refund queue"
          icon="solid-currency-dollar"
          href={Routes.admin_refund_queue_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Sales reports"
          icon="bar-chart-fill"
          href={Routes.admin_sales_reports_url(routeParams)}
          component={Link}
        />
      </section>
    </NavFramework>
  );
};

export default Nav;
