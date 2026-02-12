/*
  We need a dedicated client-side navbar that uses Inertia’s components since they rely on browser-side APIs.
  The existing server-rendered navbar cannot be reused here because doing so would require disabling pre-rendering across the app, which isn’t desirable.

  Since we’re migrating incrementally to Inertia, both navbars will coexist for now - the server-side version for pre-rendered views,
  and the client-side version for Inertia-powered views. Once the migration is complete, the server-side navbar will be phased out.
*/

import {
  Archive,
  Bank,
  BarChart,
  BookmarkHeart,
  Cart,
  DollarCircle,
  Envelope,
  MessageBubble,
  NetworkChart,
  Search,
  Store,
  Tag,
} from "@boxicons/react";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { escapeRegExp } from "$app/utils";
import { classNames } from "$app/utils/classNames";
import { initTeamMemberReadOnlyAccess } from "$app/utils/team_member_read_only";

import NavbarFooter from "$app/components/client-components/Nav/footer";
import { CloseOnNavigate } from "$app/components/CloseOnNavigate";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Nav as NavFramework, NavLink, NavSection } from "$app/components/Nav";
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
  icon?: React.ReactNode;
  badge?: React.ReactNode;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  onClick?: (event: React.MouseEvent) => void;
}) => {
  const currentPath = window.location.pathname + window.location.search;

  const ariaCurrent = [href, ...additionalPatterns].some((pattern) => {
    const patternPath = pattern.includes("://") ? new URL(pattern).pathname + new URL(pattern).search : pattern;
    const escaped = escapeRegExp(patternPath);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(currentPath);
  })
    ? "page"
    : undefined;

  return (
    <Link
      aria-current={ariaCurrent}
      href={href}
      title={text}
      {...(onClick && { onClick })}
      className={classNames(
        "flex items-center truncate border-y border-white/50 border-b-transparent px-6 py-4 no-underline last:border-b-white/50 hover:text-accent dark:border-foreground/50 dark:border-b-transparent dark:last:border-b-foreground/50",
        { "text-accent": !!ariaCurrent },
      )}
    >
      {icon}
      <span className="ml-4">{text}</span>
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
      <CloseOnNavigate />
      <NavSection>
        <ClientNavLink
          text="Home"
          icon={<Store pack="filled" className="size-4" />}
          href={Routes.dashboard_url(routeParams)}
          exactHrefMatch
        />
        <ClientNavLink
          text="Products"
          icon={<Archive pack="filled" className="size-4" />}
          href={Routes.products_url(routeParams)}
          additionalPatterns={["/bundles/"]}
        />
        {loggedInUser?.policies.collaborator.create ? (
          <ClientNavLink
            text="Collaborators"
            icon={<Tag pack="filled" className="size-4" />}
            href={Routes.collaborators_url(routeParams)}
          />
        ) : null}
        <ClientNavLink
          text="Checkout"
          icon={<Cart pack="filled" className="size-4" />}
          href={Routes.checkout_discounts_url(routeParams)}
          additionalPatterns={[Routes.checkout_form_url(routeParams), Routes.checkout_upsells_url(routeParams)]}
        />
        <ClientNavLink
          text="Emails"
          icon={<Envelope pack="filled" className="size-4" />}
          href={Routes.emails_url(routeParams)}
          additionalPatterns={[Routes.followers_url(routeParams)]}
        />
        <ClientNavLink
          text="Workflows"
          icon={<NetworkChart pack="filled" className="size-4" />}
          href={Routes.workflows_url(routeParams)}
        />
        <ClientNavLink text="Sales" icon={<DollarCircle pack="filled" className="size-4" />} href={Routes.customers_url(routeParams)} />
        <ClientNavLink
          text="Analytics"
          icon={<BarChart pack="filled" className="size-4" />}
          href={Routes.sales_dashboard_url(routeParams)}
          additionalPatterns={[
            Routes.audience_dashboard_url(routeParams),
            Routes.dashboard_utm_links_url(routeParams),
            Routes.churn_dashboard_url(routeParams),
          ]}
        />
        {loggedInUser?.policies.balance.index ? (
          <ClientNavLink text="Payouts" icon={<Bank className="size-4" />} href={Routes.balance_url(routeParams)} />
        ) : null}
        {loggedInUser?.policies.community.index ? (
          <NavLink text="Community" icon={<MessageBubble pack="filled" className="size-4" />} href={Routes.community_path(routeParams)} />
        ) : null}
      </NavSection>
      <NavSection>
        <NavLink text="Discover" icon={<Search pack="filled" className="size-4" />} href={discoverUrl} exactHrefMatch />
        {currentSeller?.id === loggedInUser?.id ? (
          <ClientNavLink
            text="Library"
            icon={<BookmarkHeart pack="filled" className="size-4" />}
            href={Routes.library_url(routeParams)}
            additionalPatterns={[Routes.wishlists_url(routeParams), Routes.reviews_url(routeParams)]}
          />
        ) : null}
      </NavSection>
    </NavFramework>
  );
};
