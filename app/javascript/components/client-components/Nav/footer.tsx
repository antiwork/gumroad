import { Link } from "@inertiajs/react";
import React from "react";

import { ClientNavLink } from "$app/components/client-components/Nav";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavLink, NavLinkDropdownItem, UnbecomeDropdownItem, NavLinkDropdownMembershipItem } from "$app/components/Nav";
import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";

function NavbarFooter() {
  const routeParams = { host: useAppDomain() };
  const loggedInUser = useLoggedInUser();
  const currentSeller = useCurrentSeller();
  const teamMemberships = loggedInUser?.teamMemberships;

  return (
    <>
      {currentSeller?.isBuyer ? (
        <NavLink text="Start selling" icon="shop-window-fill" href={Routes.dashboard_url(routeParams)} />
      ) : null}
      <ClientNavLink text="Settings" icon="gear-fill" href={Routes.settings_main_url(routeParams)} />
      <NavLink text="Help" icon="book" href={Routes.help_center_root_url(routeParams)} />
      <DashboardNavProfilePopover user={currentSeller}>
        <div role="menu">
          {teamMemberships != null && teamMemberships.length > 0 ? (
            <>
              {teamMemberships.map((teamMembership) => (
                <NavLinkDropdownMembershipItem key={teamMembership.id} teamMembership={teamMembership} />
              ))}
              <hr className="my-2" />
            </>
          ) : null}
          <NavLinkDropdownItem
            text="Profile"
            icon="shop-window-fill"
            href={Routes.root_url({ ...routeParams, host: currentSeller?.subdomain ?? routeParams.host })}
          />
          <NavLinkDropdownItem text="Affiliates" icon="gift-fill" href={Routes.affiliates_url(routeParams)} />
          <Link role="menuitem" href={Routes.logout_url(routeParams)} method="delete" className="w-full">
            <Icon name="box-arrow-in-right-fill" className="mr-3 ml-1" />
            Logout
          </Link>
          {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
        </div>
      </DashboardNavProfilePopover>
    </>
  );
}

export default NavbarFooter;
