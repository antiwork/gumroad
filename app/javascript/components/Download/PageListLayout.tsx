import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

type ScrollToTopContextValue = () => void;
const ScrollToTopContext = React.createContext<ScrollToTopContextValue | null>(null);

export const useScrollToTop = () => React.useContext(ScrollToTopContext);

export const PageListLayout = ({
  pageList,
  children,
  className,
}: {
  pageList: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) => {
  const contentRef = React.useRef<HTMLDivElement>(null);

  const scrollToTop = React.useCallback(() => {
    contentRef.current?.scrollTo({ top: 0, behavior: "instant" });
  }, []);

  return (
    <ScrollToTopContext.Provider value={scrollToTop}>
      <div
        className={classNames(
          "flex min-h-0 flex-col gap-6 bg-background p-4 [scrollbar-gutter:stable] md:p-8 lg:flex-row lg:gap-16",
          className,
        )}
      >
        <div className="flex flex-col gap-4 lg:w-80 lg:shrink-0 lg:overflow-y-auto">{pageList}</div>
        <div ref={contentRef} className="flex-1 lg:overflow-y-auto">
          {children}
        </div>
      </div>
    </ScrollToTopContext.Provider>
  );
};

export const PageList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div
      ref={ref}
      className={classNames("scoped-tailwind-preflight grid rounded-sm border bg-background", className)}
      role="tablist"
      {...props}
    />
  ),
);
PageList.displayName = "PageList";

export const PageListItem = ({
  className,
  asChild,
  isSelected,
  ...props
}: { className?: string; asChild?: boolean; isSelected?: boolean } & React.HTMLProps<HTMLDivElement>) => {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      className={classNames(
        "flex items-center gap-2 p-4 not-first:border-t first:rounded-t-sm last:rounded-b-sm",
        isSelected && "bg-active-bg",
        className,
      )}
      aria-selected={isSelected}
      {...props}
    />
  );
};
