import * as React from "react";
import { createPortal } from "react-dom";

import { classNames } from "$app/utils/classNames";

import { HeaderNavContext, isSectionTitle, TextTabsContext } from "$app/components/HeaderNavContext";
import { usePageSlots } from "$app/components/PageSlots";

/**
 * Wraps a page action the header nav already offers on every page ("New product"), so wide
 * screens do not show it twice. A phone's bar has no create button, so there the page keeps it.
 */
export const InHeaderNav = ({ children }: { children: React.ReactNode }) =>
  React.useContext(HeaderNavContext) ? (
    <div data-in-header-nav className="contents lg:hidden">
      {children}
    </div>
  ) : (
    children
  );

// A wide screen does not show what InHeaderNav wraps, so there it does not count as a control.
const EMPTY_ON_WIDE =
  "lg:[&:not(:has(:is(a,button,input,select,[role=tab]):not([data-in-header-nav],[data-in-header-nav]_*)))]:hidden";

/**
 * For an empty page's placeholder: an action its page header would have carried, shown only where
 * the header leaves it out (see `empty`).
 */
export const PlaceholderAction = ({ children }: { children: React.ReactNode }) =>
  React.useContext(HeaderNavContext) ? children : null;

export const PageHeader = React.forwardRef<
  HTMLDivElement,
  {
    title: React.ReactNode;
    actions?: React.ReactNode;
    children?: React.ReactNode;
    className?: string;
    showTitleOnMobile?: boolean;
    // The page has nothing to list yet. Under the header nav its actions are then left out: there
    // is nothing for them to act on, and the page's placeholder carries the one that matters.
    empty?: boolean;
  }
>(({ title, actions: allActions, children, className, showTitleOnMobile = false, empty = false }, ref) => {
  const headerNav = React.useContext(HeaderNavContext);
  // On a wide screen the header already names the section. The heading stays for screen readers,
  // and the tabs take its place on the row, opposite the actions.
  const titleInHeader = headerNav && isSectionTitle(title);
  const actions = headerNav && empty ? null : allActions;
  // Any other page is one thing being viewed or edited (a product, a form). Its title shows at
  // every width, and its buttons sit in a bar pinned under the page, where a form ends.
  const { footer } = usePageSlots();
  const actionsInFooter = headerNav && !titleInHeader && footer !== null;
  // Hidden while it holds no control: a search that is not filtering renders nothing.
  const hiddenWhileEmpty = classNames("[&:not(:has(:is(a,button,input,select,[role=tab])))]:hidden", EMPTY_ON_WIDE);

  return (
    <header
      className={classNames(
        "flex flex-col gap-4 border-b border-border p-4 md:p-8",
        titleInHeader &&
          "lg:min-h-16 lg:flex-row-reverse lg:flex-wrap lg:items-center lg:justify-between lg:gap-y-2 lg:py-2",
        // On a wide screen the title is hidden, so a header holding no control is an empty box.
        titleInHeader && EMPTY_ON_WIDE,
        className,
      )}
      ref={ref}
    >
      <div className={classNames("flex items-center justify-between gap-2 sm:min-h-8", titleInHeader && "lg:ml-auto")}>
        <h1
          className={classNames(
            "line-clamp-2 text-2xl",
            // Under the header nav a phone's bar carries no title, so the page shows its own.
            !showTitleOnMobile && !headerNav && "hidden! sm:block!",
            titleInHeader && "lg:sr-only!",
          )}
        >
          {title}
        </h1>
        <div
          className={classNames(
            "grid flex-1 grid-cols-2 gap-2 has-[>*:only-child]:grid-cols-1 sm:flex sm:flex-none md:-my-2",
            // The row's own padding is the spacing here, and it holds when the tabs wrap under.
            titleInHeader && "lg:my-0 lg:items-center",
          )}
        >
          {actionsInFooter ? null : actions}
        </div>
      </div>
      {actionsInFooter && actions
        ? createPortal(
            <div
              role="group"
              aria-label="Page actions"
              className={classNames(
                "grid grid-cols-2 gap-2 border-t border-border bg-body px-4 py-3 has-[>*:only-child]:grid-cols-1 sm:flex sm:justify-end md:px-8",
                hiddenWhileEmpty,
              )}
            >
              {actions}
            </div>,
            footer,
          )
        : null}
      {titleInHeader && children ? (
        // One flex item, so the row holds the tabs on one side and the actions on the other. It
        // does not shrink: tabs that do not fit beside the actions take a line of their own.
        <div className="flex min-w-0 flex-col gap-4 lg:max-w-full lg:shrink-0 lg:grow">
          <TextTabsContext.Provider value="row">{children}</TextTabsContext.Provider>
        </div>
      ) : (
        <TextTabsContext.Provider value={headerNav ? "stacked" : null}>{children}</TextTabsContext.Provider>
      )}
    </header>
  );
});
PageHeader.displayName = "PageHeader";
