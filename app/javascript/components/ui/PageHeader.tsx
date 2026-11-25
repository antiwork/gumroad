import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { HeaderNavContext, isSectionTitle, TextTabsContext } from "$app/components/HeaderNavContext";

export const PageHeader = React.forwardRef<
  HTMLDivElement,
  {
    title: React.ReactNode;
    actions?: React.ReactNode;
    children?: React.ReactNode;
    className?: string;
    showTitleOnMobile?: boolean;
  }
>(({ title, actions, children, className, showTitleOnMobile = false }, ref) => {
  const headerNav = React.useContext(HeaderNavContext);
  // On a wide screen the header already names the section. The heading stays for screen readers,
  // and the tabs take its place on the row, opposite the actions.
  const titleInHeader = headerNav && isSectionTitle(title);

  return (
    <header
      className={classNames(
        "flex flex-col gap-4 border-b border-border p-4 md:p-8",
        titleInHeader &&
          "lg:min-h-16 lg:flex-row-reverse lg:flex-wrap lg:items-center lg:justify-between lg:gap-y-3 lg:py-3",
        // Nothing left to show: no tabs, and no control the header does not already have.
        titleInHeader && !children && "lg:[&:not(:has(:is(a,button,input,select):not([data-in-header-nav])))]:hidden",
        className,
      )}
      ref={ref}
    >
      <div className={classNames("flex items-center justify-between gap-2 sm:min-h-8", titleInHeader && "lg:ml-auto")}>
        <h1
          className={classNames(
            "line-clamp-2 text-2xl",
            !showTitleOnMobile && "hidden! sm:block!",
            titleInHeader && "lg:sr-only!",
          )}
        >
          {title}
        </h1>
        <div className="grid flex-1 grid-cols-2 gap-2 has-[>*:only-child]:grid-cols-1 sm:flex sm:flex-none md:-my-2">
          {actions}
        </div>
      </div>
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
