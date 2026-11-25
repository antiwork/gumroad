import { ChevronDown } from "@boxicons/react";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { type OmnibarShortcut } from "$app/utils/omnibar";

import { Button } from "$app/components/Button";
import { matchesCurrentPath, type NavItem } from "$app/components/client-components/Nav";
import { AccountPopover } from "$app/components/client-components/Nav/footer";
import { Logo } from "$app/components/Logo";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { OmnibarTrigger } from "$app/components/Omnibar";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Menu, MenuItem } from "$app/components/ui/Menu";

const linkClasses = "flex shrink-0 items-center px-3 no-underline hover:text-accent";
// The row of links clips what does not fit, so its rings are drawn inside the link. On a
// PopoverTrigger, add outline-solid: the trigger's own outline-none would otherwise hide the ring.
const insetRing = "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-current";
// The bar marks the current page without relying on the accent colour alone.
const currentClasses = "text-accent shadow-[inset_0_-0.125rem_0_var(--color-accent)]";

/**
 * Which of a one-line row's children did not fit. The row wraps and clips, so a child that did
 * not fit sits on a later line: no widths to add up, and it holds for any font or zoom.
 */
export const useWrappedChildren = (keys: string[]) => {
  const ref = React.useRef<HTMLDivElement>(null);
  const [wrapped, setWrapped] = React.useState<string[]>([]);
  // The width the row keeps free after its last visible child, which a neighbour can close up.
  const [slack, setSlack] = React.useState(0);
  const signature = keys.join("|");

  React.useLayoutEffect(() => {
    const row = ref.current;
    if (!row) return;
    const measure = () => {
      const children = [...row.children].filter((child): child is HTMLElement => child instanceof HTMLElement);
      const firstLine = children[0]?.offsetTop ?? 0;
      const next = children.filter((child) => child.offsetTop > firstLine).map((child) => child.dataset.key ?? "");
      setWrapped((previous) => (previous.join("|") === next.join("|") ? previous : next));
      const shown = children.filter((child) => child.offsetTop <= firstLine).at(-1);
      setSlack(
        shown && next.length > 0
          ? Math.max(0, Math.floor(row.getBoundingClientRect().right - shown.getBoundingClientRect().right))
          : 0,
      );
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(row);
    return () => observer.disconnect();
  }, [signature]);

  return [ref, wrapped, slack] as const;
};

// The header's "Everything else". Its rows do not prefetch: a prefetched visit would never reach
// the server, which is what promotes a destination.
const MoreMenu = ({ items, pull }: { items: NavItem[]; pull: number }) => {
  const [open, setOpen] = React.useState(false);
  // The page being viewed can be in here, and the bar would then mark nothing.
  const holdsCurrent = items.some(matchesCurrentPath);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        // A transform, not a margin: a margin would change the row's width and so what fits in it.
        style={pull > 0 ? { transform: `translateX(-${pull}px)` } : undefined}
        className={classNames(
          "gap-1",
          linkClasses,
          "h-12",
          insetRing,
          "focus-visible:outline-solid",
          holdsCurrent && currentClasses,
        )}
      >
        More
        <ChevronDown className="size-5" aria-hidden />
      </PopoverTrigger>
      <PopoverContent className="p-0" aria-label="More destinations">
        <Menu className="border-0 shadow-none">
          {items.map((item) => (
            <MenuItem key={item.key} asChild>
              <Link
                href={item.href}
                aria-current={matchesCurrentPath(item) ? "page" : undefined}
                className="no-underline aria-[current=page]:font-bold"
                onClick={() => {
                  item.onClick?.();
                  setOpen(false);
                }}
              >
                {item.text}
              </Link>
            </MenuItem>
          ))}
        </Menu>
      </PopoverContent>
    </Popover>
  );
};

// One click for the first thing the user may create; the rest are behind the arrow.
const CreateButton = ({ actions }: { actions: OmnibarShortcut[] }) => {
  const [open, setOpen] = React.useState(false);
  const [first, ...others] = actions;
  if (!first) return null;
  // The two halves read as one button, so neither lifts on its own.
  const joined = "whitespace-nowrap hover:translate-0 hover:shadow-none";

  return (
    // h-12 matches the search field, and both halves stretch to it.
    <div className="flex h-12 shrink-0 items-stretch">
      <NavigationButtonInertia
        href={first.href}
        color="accent"
        className={classNames(joined, others.length > 0 && "rounded-r-none")}
      >
        {first.title}
      </NavigationButtonInertia>
      {others.length > 0 ? (
        <Popover open={open} onOpenChange={setOpen}>
          <PopoverTrigger asChild>
            <Button
              color="accent"
              aria-label="Create something else"
              // Inset: the ring is the button's text colour, which the black bar would swallow.
              className={classNames(joined, "-ml-px rounded-l-none px-2", insetRing, "focus-visible:outline-solid")}
            >
              <ChevronDown className="size-5" aria-hidden />
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="p-0" aria-label="Create">
            <Menu className="border-0 shadow-none">
              {others.map((action) => (
                <MenuItem key={action.id} asChild>
                  <Link href={action.href} className="no-underline" onClick={() => setOpen(false)}>
                    {action.title}
                  </Link>
                </MenuItem>
              ))}
            </Menu>
          </PopoverContent>
        </Popover>
      ) : null}
    </div>
  );
};

/**
 * The dashboard's nav across the top of a wide screen: the logo, search, create and the account
 * menu on a black row, and the destinations as text links on a row under it. Phones keep the drawer.
 *
 * `links` are the destinations to show, most important first; the ones there is no room for join
 * `more` in the menu.
 */
export const HeaderNav = ({
  links,
  more,
  actions,
  homeHref,
  onOpenSearch,
}: {
  links: NavItem[];
  more: NavItem[];
  actions: OmnibarShortcut[];
  homeHref: string;
  onOpenSearch: () => void;
}) => {
  const [rowRef, wrapped, slack] = useWrappedChildren(links.map((item) => item.key));
  const menuItems = [...links.filter((item) => wrapped.includes(item.key)), ...more];
  // The same gutter as the page under it, so the logo sits over the page's title.
  const row = "flex items-center bg-black px-4 text-white lg:px-8 dark:text-foreground";

  return (
    // Two rows, 4rem and 3rem: the layout publishes their sum as --dashboard-header-height.
    <nav aria-label="Main" className="hidden shrink-0 flex-col lg:flex">
      <div className={classNames(row, "h-16 gap-4")}>
        <a href={homeHref} aria-label="Dashboard" className="flex shrink-0 items-center no-underline">
          <Logo className="text-2xl" />
        </a>
        {/* Search starts at the logo and is capped, so it does not stretch across a very wide screen. */}
        <div className="max-w-3xl flex-1">
          <OmnibarTrigger variant="field" onOpen={onOpenSearch} className="flex h-12 w-full" />
        </div>
        <div className="ml-auto flex shrink-0 items-center gap-4">
          <CreateButton actions={actions} />
          <AccountPopover placement="header" />
        </div>
      </div>
      {/* The links' own padding insets their text, so the row's gutter is that much smaller. */}
      <div className={classNames(row, "h-12 lg:px-5")}>
        <div
          ref={rowRef}
          className="flex h-12 min-w-0 flex-wrap overflow-hidden"
          // A clipped row can still be scrolled, by find-in-page for one, to its hidden lines.
          onScroll={(event) => {
            event.currentTarget.scrollTop = 0;
          }}
        >
          {links.map((item) => {
            const current = matchesCurrentPath(item);
            return (
              <Link
                key={item.key}
                data-key={item.key}
                href={item.href}
                prefetch="hover"
                aria-current={current ? "page" : undefined}
                {...(item.onClick && { onClick: item.onClick })}
                className={classNames(
                  linkClasses,
                  "h-12",
                  insetRing,
                  current && currentClasses,
                  // On a clipped line, so in More instead. Invisible, not unmounted: it is still measured.
                  wrapped.includes(item.key) && "invisible",
                )}
              >
                {item.text}
              </Link>
            );
          })}
        </div>
        {menuItems.length > 0 ? <MoreMenu items={menuItems} pull={slack} /> : null}
      </div>
    </nav>
  );
};
