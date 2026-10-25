// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { followWishlist, unfollowWishlist } from "$app/data/wishlists";
import { ResponseError } from "$app/utils/request";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardWishlist } from "$app/components/Wishlist/Card";

vi.mock("$app/data/wishlists", () => ({ followWishlist: vi.fn(), unfollowWishlist: vi.fn() }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeEach(() => {
  vi.mocked(followWishlist).mockReset().mockResolvedValue(undefined);
  vi.mocked(unfollowWishlist).mockReset().mockResolvedValue(undefined);
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const loggedInUser = parseLoggedInUser({
  id: "buyer-1",
  email: "buyer@example.com",
  name: "Buyer",
  avatar_url: "",
  team_memberships: [],
  can_create_brand_account: false,
  has_payout_setup_to_port: false,
  can_port_bank_payout_setup: false,
  will_copy_bank_payout: false,
  policies: {},
  promoted_nav_items: [],
  confirmed: true,
  lazy_load_offscreen_discover_images: false,
});

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

const renderCard = (props: React.ComponentProps<typeof Card>, onSubmit = vi.fn()) =>
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
      <LoggedInUserProvider value={loggedInUser}>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            onSubmit();
          }}
        >
          <Card {...props} />
        </form>
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );

describe("Wishlist Card", () => {
  it.each([false, true])("renders a native, non-submitting button when following=%s", (following) => {
    renderCard({ wishlist: wishlist({ following }) });
    const button = screen.getByRole<HTMLButtonElement>("button", { name: following ? "Unfollow" : "Follow" });
    expect(button.tagName).toBe("BUTTON");
    expect(button.type).toBe("button");
    expect(button.tabIndex).toBe(0);
  });

  it.each([false, true])("blocks repeat requests while following=%s is pending", async (following) => {
    const action = vi.mocked(following ? unfollowWishlist : followWishlist);
    let complete: () => void = () => {};
    action.mockReturnValue(
      new Promise<void>((resolve) => {
        complete = resolve;
      }),
    );
    const submit = vi.fn();
    renderCard({ wishlist: wishlist({ following }) }, submit);
    const button = screen.getByRole<HTMLButtonElement>("button", { name: following ? "Unfollow" : "Follow" });
    fireEvent.click(button);
    fireEvent.click(button);
    button.click();
    expect(action).toHaveBeenCalledExactlyOnceWith({ wishlistId: "wishlist-1" });
    expect(button.disabled).toBe(true);
    expect(submit).not.toHaveBeenCalled();
    await act(async () => {
      complete();
      await Promise.resolve();
    });
    expect(screen.getByRole<HTMLButtonElement>("button", { name: following ? "Follow" : "Unfollow" }).disabled).toBe(
      false,
    );
  });

  it("follows and unfollows without submitting a containing form", async () => {
    const submit = vi.fn();
    renderCard({ wishlist: wishlist() }, submit);
    fireEvent.click(screen.getByRole("button", { name: "Follow" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Unfollow" })).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: "Unfollow" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Follow" })).toBeTruthy());
    expect(followWishlist).toHaveBeenCalledExactlyOnceWith({ wishlistId: "wishlist-1" });
    expect(unfollowWishlist).toHaveBeenCalledExactlyOnceWith({ wishlistId: "wishlist-1" });
    expect(submit).not.toHaveBeenCalled();
  });

  it.each([false, true])("allows retry after a request failure when following=%s", async (following) => {
    const action = vi.mocked(following ? unfollowWishlist : followWishlist);
    action.mockRejectedValueOnce(new ResponseError("Try again"));
    renderCard({ wishlist: wishlist({ following }) });
    fireEvent.click(screen.getByRole("button", { name: following ? "Unfollow" : "Follow" }));
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Try again", "error"));
    const retry = screen.getByRole<HTMLButtonElement>("button", { name: following ? "Unfollow" : "Follow" });
    expect(retry.disabled).toBe(false);
    fireEvent.click(retry);
    await waitFor(() => expect(screen.getByRole("button", { name: following ? "Follow" : "Unfollow" })).toBeTruthy());
    expect(action).toHaveBeenCalledTimes(2);
  });

  it("omits the follow control when the wishlist cannot be followed", () => {
    renderCard({ wishlist: wishlist({ can_follow: false }) });
    expect(screen.queryByRole("button", { name: "Follow" })).toBeNull();
  });

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
