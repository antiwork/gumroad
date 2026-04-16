import { BarChartBig, Calendar, DollarCircle, Envelope, EnvelopeOpen, Flag, LightBulb, Shield, User } from "@boxicons/react";
import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import AdminNavFooter from "$app/components/Admin/Nav/Footer";
import { CloseOnNavigate } from "$app/components/CloseOnNavigate";
import { useAppDomain } from "$app/components/DomainSettings";
import { InertiaNavLink, Nav as NavFramework, NavLink, NavSection } from "$app/components/Nav";

type PageProps = { title: string };

const Nav = () => {
  const { title } = usePage<PageProps>().props;
  const routeParams = { host: useAppDomain() };

  return (
    <NavFramework title={title} footer={<AdminNavFooter />}>
      <CloseOnNavigate />
      <NavSection>
        <InertiaNavLink
          text="Suspend users"
          icon={<Shield pack="filled" className="size-5" />}
          href={Routes.admin_suspend_users_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Block emails"
          icon={<Envelope pack="filled" className="size-5" />}
          href={Routes.admin_block_email_domains_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Unblock emails"
          icon={<EnvelopeOpen pack="filled" className="size-5" />}
          href={Routes.admin_unblock_email_domains_url(routeParams)}
          component={Link}
        />
        <NavLink
          text="Sidekiq"
          icon={<LightBulb pack="filled" className="size-5" />}
          href={Routes.admin_sidekiq_web_url(routeParams)}
        />
        <NavLink
          text="Features"
          icon={<Flag pack="filled" className="size-5" />}
          href={Routes.admin_flipper_ui_url(routeParams)}
        />
        <InertiaNavLink
          text="Refund queue"
          icon={<DollarCircle pack="filled" className="size-5" />}
          href={Routes.admin_refund_queue_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Sales reports"
          icon={<BarChartBig pack="filled" className="size-5" />}
          href={Routes.admin_sales_reports_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Scheduled payouts"
          icon={<Calendar pack="filled" className="size-5" />}
          href={Routes.admin_scheduled_payouts_url(routeParams)}
          component={Link}
        />
        <InertiaNavLink
          text="Unreviewed users"
          icon={<User pack="filled" className="size-5" />}
          href={Routes.admin_unreviewed_users_url(routeParams)}
          component={Link}
        />
      </NavSection>
    </NavFramework>
  );
};

export default Nav;
