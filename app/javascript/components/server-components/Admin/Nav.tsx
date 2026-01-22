import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import {
  Nav as NavFramework,
  NavLink,
  NavLinkDropdownItem,
  NavSection,
  UnbecomeDropdownItem,
} from "$app/components/Nav";
import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";

type ImpersonatedUser = {
  name: string;
  avatar_url: string;
};

type CurrentUser = {
  name: string;
  avatar_url: string;
  impersonated_user: ImpersonatedUser | null;
};

type Props = { title: string; current_user: CurrentUser };

export const Nav = ({ title, current_user }: Props) => {
  const routeParams = { host: useAppDomain() };
  const loggedInUser = useLoggedInUser();

  return (
    <NavFramework
      title={title}
      footer={
        <DashboardNavProfilePopover user={loggedInUser}>
          <div role="menu">
            {current_user.impersonated_user ? (
              <>
                <a role="menuitem" href={Routes.root_url()}>
                  <img className="user-avatar" src={current_user.impersonated_user.avatar_url} alt="Your avatar" />
                  <span>{current_user.impersonated_user.name}</span>
                </a>
                <hr className="my-2" />
              </>
            ) : null}
            <NavLinkDropdownItem text="Logout" icon="box-arrow-in-right-fill" href={Routes.logout_url()} />
            {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
          </div>
        </DashboardNavProfilePopover>
      }
    >
      <NavSection>
        <NavLink text="Suspend users" icon="shield-exclamation" href={Routes.admin_suspend_users_url(routeParams)} />
        <NavLink text="Block emails" icon="envelope-fill" href={Routes.admin_block_email_domains_url(routeParams)} />
        <NavLink
          text="Unblock emails"
          icon="envelope-open-fill"
          href={Routes.admin_unblock_email_domains_url(routeParams)}
        />
        <NavLink text="Sidekiq" icon="lighting-fill" href={Routes.admin_sidekiq_web_url(routeParams)} />
        <NavLink text="Features" icon="solid-flag" href={Routes.admin_flipper_ui_url(routeParams)} />
        <NavLink text="Refund queue" icon="solid-currency-dollar" href={Routes.admin_refund_queue_url(routeParams)} />
        <NavLink text="Sales reports" icon="bar-chart-fill" href={Routes.admin_sales_reports_url(routeParams)} />
        <NavLink text="Unreviewed users" icon="people-fill" href={Routes.admin_unreviewed_users_url(routeParams)} />
      </NavSection>
    </NavFramework>
  );
};

export default register({ component: Nav, propParser: createCast() });
