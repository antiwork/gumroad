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
  ChevronRight,
  DollarCircle,
  Envelope,
  FileDetail,
  Gift,
  Handshake,
  HomeAlt2,
  MessageBubble,
  Search,
  Store,
  Workflow,
} from "@boxicons/react";
import { type LinkPrefetchOption } from "@inertiajs/core";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { escapeRegExp } from "$app/utils";
import { classNames } from "$app/utils/classNames";
import { type OmnibarAgent, type OmnibarShortcut } from "$app/utils/omnibar";
import { initTeamMemberReadOnlyAccess } from "$app/utils/team_member_read_only";

import NavbarFooter from "$app/components/client-components/Nav/footer";
import { HeaderNav } from "$app/components/client-components/Nav/header";
import { CloseOnNavigate } from "$app/components/CloseOnNavigate";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Nav as NavFramework, NavSection } from "$app/components/Nav";
import { OmnibarDialog, OmnibarTrigger, useOmnibar } from "$app/components/Omnibar";
import { usePageSearch } from "$app/components/PageSearch";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  title: string;
  compact?: boolean;
};

// Matches the phone bar's transition in Nav.tsx (duration-200), less a beat so the two overlap.
const SEARCH_EXPAND_MS = 180;

export const matchesCurrentPath = ({
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

export type NavItem = {
  key: string;
  // The existing per-row authorization gate, independent of promotion: a row the user may not open
  // does not appear even inside "Everything else".
  visible: boolean;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  text: string;
  // Other words a seller might type for this destination in the search bar.
  keywords: string;
  icon: React.ReactNode;
  // Runs before the visit, whether it starts from the row or from the search bar.
  onClick?: () => void;
};

const renderItem = ({ key, visible: _visible, keywords: _keywords, ...link }: NavItem) => (
  <ClientNavLink key={key} {...link} />
);

// Overflow rows must NOT prefetch. Inertia prefetches on hover and a later click adopts that
// in-flight or cached response instead of issuing its own request, so the visit that is supposed to
// earn the row would never reach the server. Once promoted the row moves up here, where hover
// prefetch is free again because promoting an already-recorded item is a no-op.
const renderOverflowItem = ({ key, visible: _visible, keywords: _keywords, ...link }: NavItem) => (
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
      keywords: "dashboard overview",
      visible: true,
      text: "Home",
      icon: <HomeAlt2 pack="filled" className="size-5" />,
      href: Routes.dashboard_url(routeParams),
      exactHrefMatch: true,
    },
    {
      key: "profile",
      keywords: "store storefront",
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
      keywords: "landing links",
      visible: !!currentSeller && !!loggedInUser?.policies.page.index,
      text: "Pages",
      icon: <FileDetail pack="filled" className="size-5" />,
      href: Routes.pages_url(routeParams),
      additionalPatterns: ["/pages/"],
    },
    {
      key: "products",
      keywords: "bundles memberships",
      visible: true,
      text: "Products",
      icon: <ArchiveAlt pack="filled" className="size-5" />,
      href: Routes.products_url(routeParams),
      additionalPatterns: ["/bundles/"],
    },
    {
      key: "collaborators",
      keywords: "collabs partners",
      visible: !!loggedInUser?.policies.collaborator.create,
      text: "Collaborators",
      icon: <Handshake pack="filled" className="size-5" />,
      href: Routes.collaborators_url(routeParams),
    },
    {
      key: "checkout",
      keywords: "discounts offer codes upsells form",
      visible: true,
      text: "Checkout",
      icon: <Cart pack="filled" className="size-5" />,
      href: Routes.checkout_discounts_url(routeParams),
      additionalPatterns: [Routes.checkout_form_url(routeParams), Routes.checkout_upsells_url(routeParams)],
    },
    {
      key: "emails",
      keywords: "posts broadcasts newsletter followers subscribers",
      visible: true,
      text: "Emails",
      icon: <Envelope pack="filled" className="size-5" />,
      href: Routes.emails_url(routeParams),
      additionalPatterns: [Routes.followers_url(routeParams)],
    },
    {
      key: "workflows",
      keywords: "automation drip sequence",
      visible: true,
      text: "Workflows",
      icon: <Workflow pack="filled" className="size-5" />,
      href: Routes.workflows_url(routeParams),
    },
    {
      key: "sales",
      keywords: "customers buyers orders refunds",
      visible: true,
      text: "Sales",
      icon: <DollarCircle pack="filled" className="size-5" />,
      href: Routes.customers_url(routeParams),
    },
    {
      key: "analytics",
      keywords: "stats audience utm links churn",
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
      keywords: "referrals",
      visible: true,
      text: "Affiliates",
      icon: <Gift pack="filled" className="size-5" />,
      href: Routes.affiliates_url(routeParams),
    },
    {
      key: "payouts",
      keywords: "balance bank money payments",
      visible: !!loggedInUser?.policies.balance.index,
      text: "Payouts",
      icon: <Bank pack="filled" className="size-5" />,
      href: Routes.balance_url(routeParams),
    },
    {
      key: "community",
      keywords: "chat",
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
      keywords: "purchases wishlists reviews",
      visible: currentSeller?.id === loggedInUser?.id,
      text: "Library",
      icon: <BookmarkHeart pack="filled" className="size-5" />,
      href: Routes.library_url(routeParams),
      additionalPatterns: [Routes.wishlists_url(routeParams), Routes.reviews_url(routeParams)],
    },
    {
      key: "discover",
      keywords: "marketplace browse",
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

  const omnibar = useOmnibar();
  // Each opens the assistant's own chat with the question typed in; its Gumroad connector does the rest.
  const askQuestion = (question: string) => encodeURIComponent(`In my Gumroad store: ${question}`);
  const agents: OmnibarAgent[] = (loggedInUser?.askAgents ?? []).map((agent) =>
    agent === "claude"
      ? { id: agent, name: "Claude", href: (question) => `https://claude.ai/new?q=${askQuestion(question)}` }
      : { id: agent, name: "ChatGPT", href: (question) => `https://chatgpt.com/?q=${askQuestion(question)}` },
  );
  const pageSearch = usePageSearch();
  // The search bar offers every destination, including the ones still under "Everything else".
  // Shortcuts carry `id`, not `key`: dashboard_nav_spec.rb reads every `key: "…"` line in this
  // file as a nav item the server must know.
  const pages: OmnibarShortcut[] = [
    ...visibleItems.map(({ key, text, href, keywords, onClick }) => ({
      id: key,
      title: text,
      href,
      keywords,
      onSelect: onClick,
    })),
    {
      id: "settings",
      title: "Settings",
      href: Routes.settings_main_url(routeParams),
      keywords: "account preferences",
    },
    { id: "help", title: "Help", href: Routes.help_center_root_url(routeParams), keywords: "support docs" },
  ];
  const policies = loggedInUser?.policies;
  const actions: OmnibarShortcut[] = [
    {
      id: "new-product",
      title: "New product",
      href: Routes.new_product_url(routeParams),
      allowed: policies?.product.create,
    },
    {
      id: "new-email",
      title: "New email",
      href: Routes.new_email_url(routeParams),
      allowed: policies?.installment.create,
    },
    {
      id: "new-workflow",
      title: "New workflow",
      href: Routes.new_workflow_url(routeParams),
      allowed: policies?.workflow.create,
    },
  ].flatMap(({ allowed, ...action }) => (allowed ? [{ ...action, keywords: "create add" }] : []));

  const pinned = visibleItems.filter(isPinned);
  // On trial: a horizontal header on wide screens. Phones keep the drawer either way.
  const headerNav = !!loggedInUser?.headerNav;
  // The header drops links from the end when it runs out of room, so the core ones go first.
  const isCore = (item: NavItem) => CORE_ITEMS.includes(item.key);
  const headerLinks = [...pinned.filter(isCore), ...pinned.filter((item) => !isCore(item))];
  // The header's create button leads with what the section being viewed makes, since the pages
  // no longer carry a "New email" or "New workflow" button of their own.
  const sectionAction = { emails: "new-email", workflows: "new-workflow" }[
    visibleItems.find(matchesCurrentPath)?.key ?? ""
  ];
  const headerActions = [...actions].sort((a, b) => Number(b.id === sectionAction) - Number(a.id === sectionAction));
  // On a phone the search field first takes the whole bar, then the search bar opens over it.
  const [searchExpanding, setSearchExpanding] = React.useState(false);
  React.useEffect(() => {
    if (!searchExpanding) return;
    const timeout = window.setTimeout(() => {
      omnibar.show();
      setSearchExpanding(false);
    }, SEARCH_EXPAND_MS);
    return () => window.clearTimeout(timeout);
  }, [searchExpanding]);
  const openPhoneSearch = () => {
    const reduceMotion =
      typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduceMotion) omnibar.show();
    else setSearchExpanding(true);
  };

  return (
    <>
      <NavFramework
        footer={<NavbarFooter />}
        headerAction={<OmnibarTrigger variant="icon" onOpen={omnibar.show} />}
        search={
          <OmnibarTrigger
            variant="field"
            onOpen={omnibar.show}
            canAsk={agents.length > 0}
            className="mx-6 mb-6 hidden lg:flex"
          />
        }
        {...(headerNav && {
          className: "lg:hidden",
          phoneBar: {
            search: (
              <OmnibarTrigger
                variant="field"
                compact
                onOpen={openPhoneSearch}
                canAsk={agents.length > 0}
                className="flex h-10 min-w-0 flex-1"
              />
            ),
            searchExpanded: searchExpanding || omnibar.open,
          },
        })}
        {...props}
      >
        <CloseOnNavigate />
        <NavSection>
          {pinned.map(renderItem)}
          {overflow.length > 0 ? <EverythingElse>{overflow.map(renderOverflowItem)}</EverythingElse> : null}
        </NavSection>
      </NavFramework>
      {headerNav ? (
        <HeaderNav
          links={headerLinks}
          more={overflow}
          actions={headerActions}
          homeHref={Routes.root_url()}
          onOpenSearch={omnibar.show}
          canAsk={agents.length > 0}
        />
      ) : null}
      <OmnibarDialog
        open={omnibar.open}
        dictate={omnibar.dictate}
        onClose={omnibar.hide}
        pages={pages}
        actions={actions}
        pageSearch={pageSearch}
        agents={agents}
      />
    </>
  );
};

// The escape hatch for destinations a seller has not used yet. Collapsed by default so the sidebar
// stays short, and the open state is per-render only: the list shrinks as rows get promoted out of
// it, so persisting "open" would work against the thing it exists to fix.
const EverythingElse = ({ children }: { children: React.ReactNode }) => {
  const [open, setOpen] = React.useState(false);
  const listId = React.useId();
  const buttonRef = React.useRef<HTMLButtonElement>(null);

  const scrollDisclosureToTop = () => {
    const button = buttonRef.current;
    const scroller = button?.closest(".overflow-y-auto");
    if (!(button instanceof HTMLElement) || !(scroller instanceof HTMLElement)) return;
    const offset = button.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    scroller.scrollTo({
      top: scroller.scrollTop + offset,
      behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
    });
  };

  const toggle = () => {
    const next = !open;
    setOpen(next);
    // The rAF scroll starts while the grid is still at ~0fr, so the scroll target clamps to the
    // pre-expansion height; the transitionend handler below re-issues it once the rows are tall.
    if (next) requestAnimationFrame(scrollDisclosureToTop);
  };

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        aria-expanded={open}
        aria-controls={listId}
        onClick={toggle}
        className={classNames(
          // Same box as every other nav row: `all-unset` would otherwise drop border-box and the
          // row would overhang the sidebar. Bottom border is transparent so this doesn't paint a
          // double rule against the next row; the last overflow item (or this button, when closed)
          // still needs an explicit bottom edge because the following node is a sibling, not a
          // last-child row.
          "box-border flex w-full cursor-pointer items-center truncate border-y border-white/50 border-b-transparent px-6 py-4 text-left all-unset hover:text-accent dark:border-foreground/50 dark:border-b-transparent",
          !open && "border-b-white/50 dark:border-b-foreground/50",
        )}
      >
        <ChevronRight
          aria-hidden="true"
          className={classNames(
            "size-5 shrink-0 transition-transform duration-200 ease-out motion-reduce:transition-none",
            open && "rotate-90",
          )}
        />
        <span className="ml-4">Everything else</span>
      </button>
      <div
        id={listId}
        onTransitionEnd={(event) => {
          if (open && event.target === event.currentTarget && event.propertyName === "grid-template-rows")
            scrollDisclosureToTop();
        }}
        className={classNames(
          "grid transition-[grid-template-rows] duration-200 ease-out motion-reduce:transition-none",
          open ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
        )}
      >
        <div className="min-h-0 overflow-hidden" inert={!open || undefined} aria-hidden={!open}>
          {children}
        </div>
      </div>
    </>
  );
};
