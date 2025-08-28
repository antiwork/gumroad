import { HelperClientProvider } from "@helperai/react";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";
import { initTeamMemberReadOnlyAccess } from "$app/utils/team_member_read_only";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { useLoggedInUser, TeamMembership } from "$app/components/LoggedInUser";
import { Nav as NavFramework, NavLink, NavLinkDropdownItem, UnbecomeDropdownItem } from "$app/components/Nav";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
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
  };
};

const NavLinkDropdownMembershipItem = ({ teamMembership }: { teamMembership: TeamMembership }) => {
  const onClick = (ev: React.MouseEvent<HTMLAnchorElement>) => {
    const currentUrl = new URL(window.location.href);
    // It is difficult to tell if the account to be switched has access to the current page via policies in this context.
    // Pundit deals with that, and PunditAuthorization concern handles Pundit::NotAuthorizedError.
    // account_switched param is solely for the purpose of not showing the error message when redirecting to the
    // dashboard in case the user doesn't have access to the page.
    currentUrl.searchParams.set("account_switched", "true");
    ev.preventDefault();
    request({
      method: "POST",
      accept: "json",
      url: Routes.sellers_switch_path({ team_membership_id: teamMembership.id }),
    })
      .then((res) => {
        if (!res.ok) throw new ResponseError();
        window.location.href = currentUrl.toString();
      })
      .catch((e: unknown) => {
        assertResponseError(e);
        showAlert("Something went wrong.", "error");
      });
  };

  return (
    <a
      role="menuitemradio"
      href={Routes.sellers_switch_path()}
      onClick={onClick}
      aria-checked={teamMembership.is_selected}
    >
      <img className="user-avatar" src={teamMembership.seller_avatar_url} alt={teamMembership.seller_name} />
      <span title={teamMembership.seller_name}>{teamMembership.seller_name}</span>
    </a>
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
    <NavFramework
      footer={
        <>
          {currentSeller?.isBuyer ? (
            <NavLink text="Start selling" icon="shop-window-fill" href={Routes.dashboard_url(routeParams)} />
          ) : null}
          <NavLink text="Settings" icon="gear-fill" href={Routes.settings_main_url(routeParams)} />

          <NavLink
            text="Help"
            icon="book"
            href={Routes.help_center_root_url(routeParams)}
            badge={
              props.helper_host && props.helper_session ? (
                <HelperClientProvider host={props.helper_host} session={props.helper_session}>
                  <UnreadTicketsBadge />
                </HelperClientProvider>
              ) : null
            }
          />
          <Popover
            position="top"
            trigger={
              <>
                <img className="user-avatar" src={currentSeller?.avatarUrl} alt="Your avatar" />
                {currentSeller?.name || currentSeller?.email}
              </>
            }
          >
            <div role="menu">
              {teamMemberships != null && teamMemberships.length > 0 ? (
                <>
                  {teamMemberships.map((teamMembership) => (
                    <NavLinkDropdownMembershipItem key={teamMembership.id} teamMembership={teamMembership} />
                  ))}
                  <hr />
                </>
              ) : null}
              <NavLinkDropdownItem
                text="Profile"
                icon="shop-window-fill"
                href={Routes.root_url({ ...routeParams, host: currentSeller?.subdomain ?? routeParams.host })}
              />
              <NavLinkDropdownItem text="Affiliates" icon="gift-fill" href={Routes.affiliates_url(routeParams)} />
              <NavLinkDropdownItem text="Logout" icon="box-arrow-in-right-fill" href={Routes.logout_url(routeParams)} />
              {loggedInUser?.isImpersonating ? <UnbecomeDropdownItem /> : null}
            </div>
          </Popover>
        </>
      }
      {...props}
    >
      <section>
        <NavLink text="Home" icon="shop-window-fill" href={Routes.dashboard_url(routeParams)} exactHrefMatch />
        <NavLink
          text="Products"
          icon="archive-fill"
          href={Routes.products_url(routeParams)}
          additionalPatterns={[Routes.bundle_path(".", routeParams).slice(0, -1)]}
        />
        {loggedInUser?.policies.collaborator.create ? (
          <NavLink text="Collaborators" icon="deal-fill" href={Routes.collaborators_url(routeParams)} />
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
        <NavLink text="Sales" icon="solid-currency-dollar" href={Routes.customers_url(routeParams)} />
        <NavLink
          text="Analytics"
          icon="bar-chart-fill"
          href={Routes.sales_dashboard_url(routeParams)}
          additionalPatterns={[Routes.audience_dashboard_url(routeParams), Routes.utm_links_dashboard_url(routeParams)]}
        />
        {loggedInUser?.policies.balance.index ? (
          <NavLink text="Payouts" icon="bank" href={Routes.balance_url(routeParams)} />
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

export default register({ component: Nav, propParser: createCast() });
