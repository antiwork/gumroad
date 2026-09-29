// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { ResponseError } from "$app/utils/request";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

import ReviewsIndex from "./Index";

const mocks = vi.hoisted(() => ({ setProductRating: vi.fn() }));

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
vi.mock("$app/data/product_reviews", () => ({ setProductRating: mocks.setProductRating }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy({}, { get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}` }),
  });
});

afterEach(cleanup);
beforeEach(() => {
  mocks.setProductRating.mockReset();
});

const props = {
  reviews: [
    {
      id: "r1",
      anonymous: false,
      account_name: "Buyer",
      rating: 3,
      message: "A very long quote that would otherwise stretch the popover across the whole window",
      purchase_id: "pu1",
      purchase_email_digest: "digest",
      video: null,
      product: {
        name: "Alpha",
        url: "https://example.com/alpha",
        permalink: "alpha",
        thumbnail_url: null,
        native_type: "digital" as const,
        is_bundle: false,
        available: true,
        seller: { name: "Seller", url: "https://example.com/seller" },
      },
    },
  ],
  purchases: [],
};

const renderPage = () =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "app.test",
        rootDomain: "test",
        shortDomain: "short.test",
        discoverDomain: "discover.test",
        thirdPartyAnalyticsDomain: "analytics.test",
        apiDomain: "api.test",
      }}
    >
      <LoggedInUserProvider value={null}>
        <ReviewsIndex {...props} />
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );

const openEditor = () => {
  fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  return screen.getByRole("dialog");
};

describe("Reviews page edit popover", () => {
  it("gives the popover a definite width, aligned to the pencil", () => {
    renderPage();
    const popover = openEditor();

    // happy-dom does no layout, so assert the classes that fix the width. Without them the popover
    // falls back to `w-max` and the unwrapped quote stretches it to the viewport cap.
    expect(popover.className).toContain("w-[min(28rem,calc(100vw-2rem))]");
    expect(popover.getAttribute("data-align")).toBe("end");
  });

  it("closes the popover after Update review saves", async () => {
    mocks.setProductRating.mockResolvedValue({
      anonymous: false,
      rating: 4,
      message: "Updated message",
      video: null,
    });
    renderPage();
    const popover = openEditor();

    fireEvent.click(within(popover).getByRole("button", { name: "Edit" }));
    fireEvent.click(within(popover).getByRole("radio", { name: "4 stars" }));
    fireEvent.click(within(popover).getByRole("button", { name: "Update review" }));

    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(popover.isConnected).toBe(false);
    expect(mocks.setProductRating).toHaveBeenCalledTimes(1);
    expect(screen.getByText('"Updated message"')).toBeTruthy();
  });

  it("keeps the popover open when the save fails", async () => {
    mocks.setProductRating.mockRejectedValue(new ResponseError("nope"));
    renderPage();
    const popover = openEditor();

    fireEvent.click(within(popover).getByRole("button", { name: "Edit" }));
    fireEvent.click(within(popover).getByRole("button", { name: "Update review" }));

    await waitFor(() => expect(mocks.setProductRating).toHaveBeenCalled());
    expect(screen.getByRole("dialog")).toBeTruthy();
  });
});
