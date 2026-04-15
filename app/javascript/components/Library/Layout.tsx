import { Link } from "@inertiajs/react";
import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useOnScrollToBottom } from "$app/components/useOnScrollToBottom";

export const Layout = ({
  selectedTab,
  onScrollToBottom,
  reviewsPageEnabled = true,
  followingWishlistsEnabled = true,
  children,
}: {
  selectedTab: "purchases" | "wishlists" | "following_wishlists" | "reviews";
  onScrollToBottom?: () => void;
  reviewsPageEnabled?: boolean;
  followingWishlistsEnabled: boolean;
  children: React.ReactNode;
}) => {
  const ref = React.useRef<HTMLDivElement>(null);

  useOnScrollToBottom(ref, () => onScrollToBottom?.(), 30);

  return (
    <div className="library" ref={ref}>
      <PageHeader title="Library">
        <Tabs>
          <Tab isSelected={selectedTab === "purchases"} asChild>
            <Link href={Routes.library_path()}>Purchases</Link>
          </Tab>
          <Tab isSelected={selectedTab === "wishlists"} asChild>
            <Link href={Routes.wishlists_path()}>{followingWishlistsEnabled ? "Saved" : "Wishlists"}</Link>
          </Tab>
          {followingWishlistsEnabled ? (
            <Tab isSelected={selectedTab === "following_wishlists"} asChild>
              <Link href={Routes.wishlists_following_index_path()}>Following</Link>
            </Tab>
          ) : null}
          {reviewsPageEnabled ? (
            <Tab isSelected={selectedTab === "reviews"} asChild>
              <Link href={Routes.reviews_path()}>Reviews</Link>
            </Tab>
          ) : null}
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};
Layout.displayName = "Layout";
