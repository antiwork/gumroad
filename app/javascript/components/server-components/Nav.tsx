import {
  Archive,
  ArrowFromLeft,
  Bank,
  BarChartBig,
  Book,
  BookmarkHeart,
  Cart,
  DollarCircle,
  Envelope,
  Cog,
  Gift,
  MessageBubble,
  Search,
  Store,
  Handshake,
  Workflow,
  HomeAlt2,
} from "@boxicons/react";
import { HelperClientProvider } from "@helperai/react";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";
import { initTeamMemberReadOnlyAccess } from "$app/utils/team_member_read_only";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import {
  Nav as NavFramework,
  NavLink,
  NavLinkDropdownItem,
  NavLinkDropdownMembershipItem,
  NavSection,
  UnbecomeDropdownItem,
} from "$app/components/Nav";
import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";
import { UnreadTicketsBadge } from "$app/components/support/UnreadTicketsBadge";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  title: string;
  compact?: boolean;
  helper_host?: string | null;
  helper_session?: {
    email?: string | null;
    emailHash?: string | null;
    timestamp?: number | null;
    customerMetadata?: {
      name?: string | null;
      value?: number | null;
      links?: Record<string, string> | null;
    } | null;
    currentToken?: string | null;
  } | null;
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
    <NavFramework
      footer={
        <>
          {currentSeller?.isBuyer ? (
            <NavLink
              text="Start selling"
              icon={<Store pack="filled" className="size-5" />}
              href={Routes.dashboard_url(routeParams)}
            />
          ) : null}
          <NavLink
            text="Settings"
            icon={<Cog pack="filled" className="size-5" />}
            href={Routes.settings_main_url(routeParams)}
          />

          <NavLink
            text="Help"
            icon={<Book pack="filled" className="size-5" />}
            href={Routes.help_center_root_url(routeParams)}
            badge={
              props.helper_host && props.helper_session ? (
                <HelperClientProvider host={props.helper_host} session={props.helper_session}>
                  <UnreadTicketsBadge />
                </HelperClientProvider>
              ) : null
            }
          />
          <DashboardNavProfilePopover user={currentSeller}>
            <div role="menu" className="border-0! shadow-none! dark:border!">
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
              <NavLinkDropdownItem
                text="Logout"
                icon={<ArrowFromLeft pack="filled" className="mr-3 ml-1 size-5" />}
                href={Routes.logout_url(routeParams)}
              />
              {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
            </div>
          </DashboardNavProfilePopover>
        </>
      }
      {...props}
    >
      <NavSection>
        <NavLink
          text="Home"
          icon={<HomeAlt2 pack="filled" className="size-5" />}
          href={Routes.dashboard_url(routeParams)}
          exactHrefMatch
        />
        <NavLink
          text="Products"
          icon={<Archive pack="filled" className="size-5" />}
          href={Routes.products_url(routeParams)}
          additionalPatterns={["/bundles/"]}
        />
        {loggedInUser?.policies.collaborator.create ? (
          <NavLink
            text="Collaborators"
            icon={<Handshake pack="filled" className="size-5" />}
            href={Routes.collaborators_url(routeParams)}
          />
        ) : null}
        <NavLink
          text="Checkout"
          icon={<Cart pack="filled" className="size-5" />}
          href={Routes.checkout_discounts_url(routeParams)}
          additionalPatterns={[Routes.checkout_form_url(routeParams), Routes.checkout_upsells_url(routeParams)]}
        />
        <NavLink
          text="Emails"
          icon={<Envelope pack="filled" className="size-5" />}
          href={Routes.emails_url(routeParams)}
          additionalPatterns={[Routes.followers_url(routeParams)]}
        />
        <NavLink
          text="Workflows"
          icon={<Workflow pack="filled" className="size-5" />}
          href={Routes.workflows_url(routeParams)}
        />
        <NavLink
          text="Sales"
          icon={<DollarCircle pack="filled" className="size-5" />}
          href={Routes.customers_url(routeParams)}
        />
        <NavLink
          text="Analytics"
          icon={<BarChartBig pack="filled" className="size-5" />}
          href={Routes.sales_dashboard_url(routeParams)}
          additionalPatterns={[
            Routes.audience_dashboard_url(routeParams),
            Routes.dashboard_utm_links_url(routeParams),
            Routes.churn_dashboard_url(routeParams),
          ]}
        />
        {loggedInUser?.policies.balance.index ? (
          <NavLink
            text="Payouts"
            icon={<Bank pack="filled" className="size-5" />}
            href={Routes.balance_url(routeParams)}
          />
        ) : null}
        {loggedInUser?.policies.community.index ? (
          <NavLink
            text="Community"
            icon={<MessageBubble pack="filled" className="size-5" />}
            href={Routes.communities_path()}
          />
        ) : null}
      </NavSection>
      <NavSection>
        <NavLink text="Discover" icon={<Search className="size-5" />} href={discoverUrl} exactHrefMatch />
        {currentSeller?.id === loggedInUser?.id ? (
          <NavLink
            text="Library"
            icon={<BookmarkHeart pack="filled" className="size-5" />}
            href={Routes.library_url(routeParams)}
            additionalPatterns={[Routes.wishlists_url(routeParams), Routes.reviews_url(routeParams)]}
          />
        ) : null}
      </NavSection>
    </NavFramework>
  );
};

export default register({ component: Nav, propParser: createCast() });
