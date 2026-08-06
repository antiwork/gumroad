/*
  We need a dedicated client-side navbar that uses Inertia’s components since they rely on browser-side APIs.
  The existing server-rendered navbar cannot be reused here because doing so would require disabling pre-rendering across the app, which isn’t desirable.

  Since we’re migrating incrementally to Inertia, both navbars will coexist for now - the server-side version for pre-rendered views,
  and the client-side version for Inertia-powered views. Once the migration is complete, the server-side navbar will be phased out.
*/

import {
  ArchiveAlt,
  Bank,
  BarChartBig,
  BookmarkHeart,
  Cart,
  DollarCircle,
  DotsHorizontalRounded,
  Envelope,
  FileDetail,
  Gift,
  Handshake,
  HomeAlt2,
  MessageBubble,
  MessageBubbleDots,
  Search,
  Store,
  Workflow,
} from "@boxicons/react";
import { type LinkPrefetchOption } from "@inertiajs/core";
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
import { Nav as NavFramework, NavSection } from "$app/components/Nav";
import { Pill } from "$app/components/ui/Pill";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  title: string;
  compact?: boolean;
};

const matchesCurrentPath = ({
  href,
  additionalPatterns = [],
  exactHrefMatch,
}: {
  href: string;
  additionalPatterns?: string[] | undefined;
  exactHrefMatch?: boolean | undefined;
}) => {
  const currentPath = window.location.pathname + window.location.search;

  return [href, ...additionalPatterns].some((pattern) => {
    const patternPath = pattern.includes("://") ? new URL(pattern).pathname + new URL(pattern).search : pattern;
    const escaped = escapeRegExp(patternPath);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(currentPath);
  });
};

export const ClientNavLink = ({
  text,
  icon,
  badge,
  href,
  exactHrefMatch,
  additionalPatterns = [],
  onClick,
  prefetch = "hover",
}: {
  text: string;
  icon?: React.ReactNode;
  badge?: React.ReactNode;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  onClick?: (event: React.MouseEvent) => void;
  prefetch?: boolean | LinkPrefetchOption | LinkPrefetchOption[];
}) => {
  const ariaCurrent = matchesCurrentPath({ href, additionalPatterns, exactHrefMatch }) ? "page" : undefined;

  return (
    <Link
      aria-current={ariaCurrent}
      href={href}
      prefetch={prefetch}
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

// Keys match DashboardNav::CORE_ITEMS / PROMOTABLE_ITEMS — the server records promotions under these
// names, so renaming one here needs the same rename in app/models/dashboard_nav.rb.
const CORE_ITEMS = ["home", "products", "sales", "payouts", "discover"];

type NavItem = {
  key: string;
  // The existing per-row authorization gate, independent of promotion: a row the user may not open
  // does not appear even inside "Everything else".
  visible: boolean;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  text: string;
  icon: React.ReactNode;
  badge?: React.ReactNode;
  onClick?: (event: React.MouseEvent) => void;
};

const renderItem = ({ key, visible: _visible, ...link }: NavItem) => <ClientNavLink key={key} {...link} />;

// Overflow rows must NOT prefetch. Inertia prefetches on hover and a later click adopts that
// in-flight or cached response instead of issuing its own request, so the visit that is supposed to
// earn the row would never reach the server. Once promoted the row moves up here, where hover
// prefetch is free again because promoting an already-recorded item is a no-op.
const renderOverflowItem = ({ key, visible: _visible, ...link }: NavItem) => (
  <ClientNavLink key={key} {...link} prefetch={false} />
);

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

  const navItems: NavItem[] = [
    {
      key: "home",
      visible: true,
      text: "Home",
      icon: <HomeAlt2 pack="filled" className="size-5" />,
      href: Routes.dashboard_url(routeParams),
      exactHrefMatch: true,
    },
    {
      key: "agent",
      // Role, not eligibility: a seller under the earned-access bar keeps the tab and is told why
      // it is locked when they open it, rather than watching it disappear.
      visible: !!loggedInUser?.policies.user.view_store_agent,
      text: "Agent",
      icon: <MessageBubbleDots pack="filled" className="size-5" />,
      // The row itself states the bar so a seller who never opens the tab still learns why it
      // isn't pinned yet (gumroad-private#1773) — isPinned below keeps it out of the core list
      // until they've earned it or used it once.
      badge: loggedInUser?.agentNavBadge ? (
        <Pill size="small" className="shrink-0 text-xs">
          {loggedInUser.agentNavBadge}
        </Pill>
      ) : undefined,
      href: Routes.agent_url(routeParams),
      exactHrefMatch: true,
    },
    {
      key: "profile",
      visible: !!currentSeller,
      text: "Profile",
      icon: <Store pack="filled" className="size-5" />,
      href: Routes.profile_url(routeParams),
      exactHrefMatch: true,
    },
    {
      // Pages sits alongside Profile: Profile jumps straight to the public storefront, while Pages
      // manages the full page tree (with the profile pinned as its home page).
      key: "pages",
      visible: !!currentSeller && !!loggedInUser?.policies.page.index,
      text: "Pages",
      icon: <FileDetail pack="filled" className="size-5" />,
      href: Routes.pages_url(routeParams),
      additionalPatterns: ["/pages/"],
    },
    {
      key: "products",
      visible: true,
      text: "Products",
      icon: <ArchiveAlt pack="filled" className="size-5" />,
      href: Routes.products_url(routeParams),
      additionalPatterns: ["/bundles/"],
    },
    {
      key: "collaborators",
      visible: !!loggedInUser?.policies.collaborator.create,
      text: "Collaborators",
      icon: <Handshake pack="filled" className="size-5" />,
      href: Routes.collaborators_url(routeParams),
    },
    {
      key: "checkout",
      visible: true,
      text: "Checkout",
      icon: <Cart pack="filled" className="size-5" />,
      href: Routes.checkout_discounts_url(routeParams),
      additionalPatterns: [Routes.checkout_form_url(routeParams), Routes.checkout_upsells_url(routeParams)],
    },
    {
      key: "emails",
      visible: true,
      text: "Emails",
      icon: <Envelope pack="filled" className="size-5" />,
      href: Routes.emails_url(routeParams),
      additionalPatterns: [Routes.followers_url(routeParams)],
    },
    {
      key: "workflows",
      visible: true,
      text: "Workflows",
      icon: <Workflow pack="filled" className="size-5" />,
      href: Routes.workflows_url(routeParams),
    },
    {
      key: "sales",
      visible: true,
      text: "Sales",
      icon: <DollarCircle pack="filled" className="size-5" />,
      href: Routes.customers_url(routeParams),
    },
    {
      key: "analytics",
      visible: true,
      text: "Analytics",
      icon: <BarChartBig pack="filled" className="size-5" />,
      href: Routes.sales_dashboard_url(routeParams),
      additionalPatterns: [
        Routes.audience_dashboard_url(routeParams),
        Routes.dashboard_utm_links_url(routeParams),
        Routes.churn_dashboard_url(routeParams),
      ],
    },
    {
      key: "affiliates",
      visible: true,
      text: "Affiliates",
      icon: <Gift pack="filled" className="size-5" />,
      href: Routes.affiliates_url(routeParams),
    },
    {
      key: "payouts",
      visible: !!loggedInUser?.policies.balance.index,
      text: "Payouts",
      icon: <Bank pack="filled" className="size-5" />,
      href: Routes.balance_url(routeParams),
    },
    {
      key: "community",
      visible: !!loggedInUser?.policies.community.index,
      text: "Community",
      icon: <MessageBubble pack="filled" className="size-5" />,
      href: Routes.communities_path(),
      onClick: () => {
        sessionStorage.setItem("communities:referrer", window.location.pathname + window.location.search);
      },
    },
    {
      key: "library",
      visible: currentSeller?.id === loggedInUser?.id,
      text: "Library",
      icon: <BookmarkHeart pack="filled" className="size-5" />,
      href: Routes.library_url(routeParams),
      additionalPatterns: [Routes.wishlists_url(routeParams), Routes.reviews_url(routeParams)],
    },
    {
      key: "discover",
      visible: true,
      text: "Discover",
      icon: <Search className="size-5" />,
      href: discoverUrl,
      exactHrefMatch: true,
    },
  ];

  const promoted = new Set(loggedInUser?.promotedNavItems ?? []);
  // The page being viewed is pinned regardless of its promotion state, which covers the render that
  // races the promotion write and keeps the current row out of the overflow.
  const isPinned = (item: NavItem) =>
    CORE_ITEMS.includes(item.key) || promoted.has(item.key) || matchesCurrentPath(item);

  const visibleItems = navItems.filter((item) => item.visible);
  const overflow = visibleItems.filter((item) => !isPinned(item));

  return (
    <NavFramework footer={<NavbarFooter />} {...props}>
      <CloseOnNavigate />
      <NavSection>{visibleItems.filter(isPinned).map(renderItem)}</NavSection>
      {overflow.length > 0 ? (
        <NavSection>
          <EverythingElse>{overflow.map(renderOverflowItem)}</EverythingElse>
        </NavSection>
      ) : null}
    </NavFramework>
  );
};

// The escape hatch for destinations a seller has not used yet. Collapsed by default so the sidebar
// stays short, and the open state is per-render only: the list shrinks as rows get promoted out of
// it, so persisting "open" would work against the thing it exists to fix.
const EverythingElse = ({ children }: { children: React.ReactNode }) => {
  const [open, setOpen] = React.useState(false);
  const listId = React.useId();

  return (
    <>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={listId}
        onClick={() => setOpen((prev) => !prev)}
        className={classNames(
          // `all-unset` clears box-sizing too, so `w-full` plus `px-6` would make the row 48px
          // wider than the sidebar and the overhang would only be hidden by the nav's clip.
          "box-border flex w-full cursor-pointer items-center truncate border-y border-white/50 px-6 py-4 text-left all-unset hover:text-accent dark:border-foreground/50",
          // The button can never be :last-child (the controlled region always follows it), so it
          // closes the section itself while collapsed rather than borrowing `last:border-b`.
          open ? "border-b-transparent dark:border-b-transparent" : "border-b-white/50 dark:border-b-foreground/50",
        )}
      >
        <DotsHorizontalRounded className="size-5" />
        <span className="ml-4">Everything else</span>
      </button>
      <div id={listId} className="grid">
        {open ? children : null}
      </div>
    </>
  );
};
