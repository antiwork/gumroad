import { ChevronLeft, ChevronRight } from "@boxicons/react";
import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";

// On phones the tab row can end exactly between two tabs and look complete, so mark each edge that
// still has tabs past it. The marks sit in the header's side padding, clear of the tabs and their taps.
const useOverflowEdges = () => {
  const listRef = React.useRef<HTMLDivElement>(null);
  const [edges, setEdges] = React.useState({ start: false, end: false });

  React.useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const update = () => {
      const start = list.scrollLeft > 1;
      const end = list.scrollLeft < list.scrollWidth - list.clientWidth - 1;
      setEdges((edges) => (edges.start === start && edges.end === end ? edges : { start, end }));
    };
    update();
    if ("fonts" in document) void document.fonts.ready.then(update);
    list.addEventListener("scroll", update, { passive: true });
    const observer = new ResizeObserver(update);
    observer.observe(list);
    return () => {
      list.removeEventListener("scroll", update);
      observer.disconnect();
    };
  }, []);

  return { listRef, edges };
};

export const Layout = ({
  selectedTab,
  children,
}: {
  selectedTab: "purchases" | "subscriptions" | "wishlists" | "following_wishlists" | "reviews";
  children: React.ReactNode;
}) => {
  const { listRef, edges } = useOverflowEdges();

  return (
    <div className="library">
      <PageHeader title="Library">
        <div className="relative">
          <Tabs ref={listRef}>
            <Tab isSelected={selectedTab === "purchases"} asChild>
              <Link href={Routes.library_path()}>Purchases</Link>
            </Tab>
            <Tab isSelected={selectedTab === "subscriptions"} asChild>
              <Link href={Routes.library_path({ subscriptions_only: true })}>Subscriptions</Link>
            </Tab>
            <Tab isSelected={selectedTab === "wishlists"} asChild>
              <Link href={Routes.wishlists_path()}>Saved</Link>
            </Tab>
            <Tab isSelected={selectedTab === "following_wishlists"} asChild>
              <Link href={Routes.wishlists_following_index_path()}>Following</Link>
            </Tab>
            <Tab isSelected={selectedTab === "reviews"} asChild>
              <Link href={Routes.reviews_path()}>Reviews</Link>
            </Tab>
          </Tabs>
          {edges.start ? (
            <ChevronLeft
              aria-hidden="true"
              className="pointer-events-none absolute top-1/2 -left-4 size-4 -translate-y-1/2"
            />
          ) : null}
          {edges.end ? (
            <ChevronRight
              aria-hidden="true"
              className="pointer-events-none absolute top-1/2 -right-4 size-4 -translate-y-1/2"
            />
          ) : null}
        </div>
      </PageHeader>
      {children}
    </div>
  );
};
Layout.displayName = "Layout";
