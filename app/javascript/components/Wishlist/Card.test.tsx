// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";
import { Card, CardWishlist } from "$app/components/Wishlist/Card";

afterEach(cleanup);

const wishlist = (overrides: Partial<CardWishlist> = {}): CardWishlist => ({
  id: "wishlist-1",
  url: "https://seller.gumroad.com/wishlists/example",
  name: "Example wishlist",
  description: null,
  seller: { id: "seller-1", name: "Seller", profile_url: "https://seller.gumroad.com", avatar_url: "" },
  thumbnails: [],
  product_count: 1,
  follower_count: 0,
  following: false,
  can_follow: true,
  ...overrides,
});

const renderCard = (props: React.ComponentProps<typeof Card>) =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gum.co",
        discoverDomain: "discover.gumroad.com",
        thirdPartyAnalyticsDomain: "analytics.gumroad.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <LoggedInUserProvider value={null}>
        <Card {...props} />
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );

describe("Wishlist Card", () => {
  // No <img> should render when there are no thumbnails — the figure's own
  // placeholder background covers the empty case.
  it("renders no <img> when the wishlist has no thumbnails", () => {
    const { container } = renderCard({ wishlist: wishlist({ thumbnails: [] }) });

    expect(container.querySelectorAll("figure img")).toHaveLength(0);
  });

  it("still renders an <img> per thumbnail when thumbnails exist", () => {
    const { container } = renderCard({
      wishlist: wishlist({
        thumbnails: [
          { url: "https://example.com/one.png", native_type: "digital" },
          { url: "https://example.com/two.png", native_type: "digital" },
        ],
      }),
    });

    expect(container.querySelectorAll("figure img")).toHaveLength(2);
  });
});
