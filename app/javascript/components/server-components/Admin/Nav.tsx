import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Nav as NavFramework, NavLink, NavLinkDropdownItem, UnbecomeDropdownItem } from "$app/components/Nav";
import { Popover } from "$app/components/Popover";

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
        <Popover
          position="top"
          trigger={
            <>
              <img className="user-avatar" src={current_user.avatar_url} alt="Your avatar" />
              {current_user.name}
            </>
          }
        >
          <div role="menu">
            {current_user.impersonated_user ? (
              <>
                <a role="menuitem" href={Routes.root_url()}>
                  <img className="user-avatar" src={current_user.impersonated_user.avatar_url} alt="Your avatar" />
                  <span>{current_user.impersonated_user.name}</span>
                </a>
                <hr />
              </>
            ) : null}
            <NavLinkDropdownItem text="Logout" icon="box-arrow-in-right-fill" href={Routes.logout_url()} />
            {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
          </div>
        </Popover>
      }
    >
      <section>
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
      </section>
    </NavFramework>
  );
};

export default register({ component: Nav, propParser: createCast() });
