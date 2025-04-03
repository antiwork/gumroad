import * as React from "react";

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
  const ref = React.useRef<HTMLElement>(null);

  useOnScrollToBottom(ref, () => onScrollToBottom?.(), 30);

  return (
    <main className="library" ref={ref}>
      <header>
        <h1>Library</h1>
        <div role="tablist">
          <a href={Routes.library_path()} role="tab" aria-selected={selectedTab === "purchases"}>
            Purchases
          </a>
          <a href={Routes.wishlists_path()} role="tab" aria-selected={selectedTab === "wishlists"}>
            {followingWishlistsEnabled ? "Saved" : "Wishlists"}
          </a>
          {followingWishlistsEnabled ? (
            <a
              href={Routes.wishlists_following_index_path()}
              role="tab"
              aria-selected={selectedTab === "following_wishlists"}
            >
              Following
            </a>
          ) : null}
          {reviewsPageEnabled ? (
            <a href={Routes.reviews_path()} role="tab" aria-selected={selectedTab === "reviews"}>
              Reviews
            </a>
          ) : null}
        </div>
      </header>
      {children}
    </main>
  );
};
Layout.displayName = "Layout";
