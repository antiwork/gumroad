import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";
import { TabPills, TabPill } from "$app/components/ui/TabPills";
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
        <TabPills>
          <TabPill href={Routes.library_path()} isSelected={selectedTab === "purchases"}>
            Purchases
          </TabPill>
          <TabPill href={Routes.wishlists_path()} isSelected={selectedTab === "wishlists"}>
            {followingWishlistsEnabled ? "Saved" : "Wishlists"}
          </TabPill>
          {followingWishlistsEnabled ? (
            <TabPill href={Routes.wishlists_following_index_path()} isSelected={selectedTab === "following_wishlists"}>
              Following
            </TabPill>
          ) : null}
          {reviewsPageEnabled ? (
            <TabPill href={Routes.reviews_path()} isSelected={selectedTab === "reviews"}>
              Reviews
            </TabPill>
          ) : null}
        </TabPills>
      </PageHeader>
      {children}
    </div>
  );
};
Layout.displayName = "Layout";
