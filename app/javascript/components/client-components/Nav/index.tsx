/*
  We need a dedicated client-side navbar that uses Inertia’s components since they rely on browser-side APIs.
  The existing server-rendered navbar cannot be reused here because doing so would require disabling pre-rendering across the app, which isn’t desirable.

  Since we’re migrating incrementally to Inertia, both navbars will coexist for now - the server-side version for pre-rendered views,
  and the client-side version for Inertia-powered views. Once the migration is complete, the server-side navbar will be phased out.
*/

import { Link } from "@inertiajs/react";
import * as React from "react";

import { escapeRegExp } from "$app/utils";
import { initTeamMemberReadOnlyAccess } from "$app/utils/team_member_read_only";

import NavbarFooter from "$app/components/client-components/Nav/footer";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Nav as NavFramework, NavLink } from "$app/components/Nav";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  title: string;
  compact?: boolean;
};

export const ClientNavLink = ({
  text,
  icon,
  badge,
  href,
  exactHrefMatch,
  additionalPatterns = [],
  onClick,
}: {
  text: string;
  icon?: IconName;
  badge?: React.ReactNode;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  onClick?: (event: React.MouseEvent) => void;
}) => {
  const currentPath = window.location.href;

  const ariaCurrent = [href, ...additionalPatterns].some((pattern) => {
    const escaped = escapeRegExp(pattern);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(currentPath);
  })
    ? "page"
    : undefined;

  return (
    <Link aria-current={ariaCurrent} href={href} title={text} {...(onClick && { onClick })}>
      {icon ? <Icon name={icon} /> : null}
      {text}
      {badge ? (
        <>
          <span className="flex-1" />
          {badge}
        </>
      ) : null}
    </Link>
  );
};

export const Nav = (props: Props) => {
  const routeParams = { host: useAppDomain() };
  const loggedInUser = useLoggedInUser();
  const currentSeller = useCurrentSeller();
  const discoverUrl = useDiscoverUrl();
  const teamMemberships = loggedInUser?.teamMemberships;

  React.useEffect(() => {
    const selectedTeamMembership = teamMemberships?.find((teamMembership) => teamMembership.is_selected);
    // Only initialize the code if loggedInUser's team membership role has some read-only access
    // It applies to all roles except Owner and Admin
    if (selectedTeamMembership?.has_some_read_only_access) {
      initTeamMemberReadOnlyAccess();
    }
  }, []);

  // Removes the param set when switching accounts
  useRunOnce(() => {
    const url = new URL(window.location.href);
    const accountSwitched = url.searchParams.get("account_switched");
    if (accountSwitched) {
      url.searchParams.delete("account_switched");
      window.history.replaceState(window.history.state, "", url.toString());
    }
  });

  return (
    <NavFramework footer={<NavbarFooter />} {...props}>
      <section>
        <ClientNavLink text="Home" icon="shop-window-fill" href={Routes.dashboard_url(routeParams)} exactHrefMatch />
        <ClientNavLink
          text="Products"
          icon="archive-fill"
          href={Routes.products_url(routeParams)}
          additionalPatterns={[Routes.bundle_path(".", routeParams).slice(0, -1)]}
        />
        {loggedInUser?.policies.collaborator.create ? (
          <ClientNavLink text="Collaborators" icon="deal-fill" href={Routes.collaborators_url(routeParams)} />
        ) : null}
        <NavLink
          text="Checkout"
          icon="cart3-fill"
          href={Routes.checkout_discounts_url(routeParams)}
          additionalPatterns={[Routes.checkout_form_url(routeParams), Routes.checkout_upsells_url(routeParams)]}
        />
        <NavLink
          text="Emails"
          icon="envelope-fill"
          href={Routes.emails_url(routeParams)}
          additionalPatterns={[Routes.followers_url(routeParams)]}
        />
        <NavLink text="Workflows" icon="diagram-2-fill" href={Routes.workflows_url(routeParams)} />
        <ClientNavLink text="Sales" icon="solid-currency-dollar" href={Routes.customers_url(routeParams)} />
        <ClientNavLink
          text="Analytics"
          icon="bar-chart-fill"
          href={Routes.sales_dashboard_url(routeParams)}
          additionalPatterns={[Routes.audience_dashboard_url(routeParams), Routes.utm_links_dashboard_url(routeParams)]}
        />
        {loggedInUser?.policies.balance.index ? (
          <ClientNavLink text="Payouts" icon="bank" href={Routes.balance_url(routeParams)} />
        ) : null}
        {loggedInUser?.policies.community.index ? (
          <NavLink text="Community" icon="solid-chat-alt" href={Routes.community_path(routeParams)} />
        ) : null}
      </section>
      <section>
        <NavLink text="Discover" icon="solid-search" href={discoverUrl} exactHrefMatch />
        {currentSeller?.id === loggedInUser?.id ? (
          <NavLink
            text="Library"
            icon="bookmark-heart-fill"
            href={Routes.library_url(routeParams)}
            additionalPatterns={[Routes.wishlists_url(routeParams)]}
          />
        ) : null}
      </section>
    </NavFramework>
  );
};
