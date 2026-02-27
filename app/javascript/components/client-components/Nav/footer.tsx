import { ArrowOutRightSquareHalf, Book, Cog, Gift, Store } from "@boxicons/react";
import { Link } from "@inertiajs/react";
import React from "react";

import { ClientNavLink } from "$app/components/client-components/Nav";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavLink, NavLinkDropdownItem, NavLinkDropdownMembershipItem, UnbecomeDropdownItem } from "$app/components/Nav";
import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";

function NavbarFooter() {
  const routeParams = { host: useAppDomain() };
  const loggedInUser = useLoggedInUser();
  const currentSeller = useCurrentSeller();
  const teamMemberships = loggedInUser?.teamMemberships;

  return (
    <>
      {currentSeller?.isBuyer ? (
        <NavLink
          text="Start selling"
          icon={<Store pack="filled" className="size-5" />}
          href={Routes.dashboard_url(routeParams)}
        />
      ) : null}
      <ClientNavLink
        text="Settings"
        icon={<Cog pack="filled" className="size-5" />}
        href={Routes.settings_main_url(routeParams)}
      />
      <ClientNavLink
        text="Help"
        icon={<Book pack="filled" className="size-5" />}
        href={Routes.help_center_root_url(routeParams)}
      />
      <DashboardNavProfilePopover user={currentSeller}>
        <div role="menu" className="flex flex-col border-0! shadow-none! dark:border!">
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
            icon={<Store pack="filled" className="mr-3 ml-1 size-5" />}
            href={Routes.root_url({ ...routeParams, host: currentSeller?.subdomain ?? routeParams.host })}
          />
          <NavLinkDropdownItem
            text="Affiliates"
            icon={<Gift pack="filled" className="mr-3 ml-1 size-5" />}
            href={Routes.affiliates_url(routeParams)}
          />
          <Link role="menuitem" href={Routes.logout_url(routeParams)} method="delete" className="all-unset">
            <ArrowOutRightSquareHalf pack="filled" className="mr-3 ml-1 size-5" />
            Logout
          </Link>
          {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
        </div>
      </DashboardNavProfilePopover>
    </>
  );
}

export default NavbarFooter;
