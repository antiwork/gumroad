// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

import ReviewsIndex from "./Index";

const mocks = vi.hoisted(() => ({ setProductRating: vi.fn() }));

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/data/product_reviews", () => ({
  setProductRating: mocks.setProductRating,
  getReviewVideoUploadContext: vi.fn(),
}));
// The uploader fetches S3 credentials once a video review is chosen; a text edit needs none.
vi.mock("$app/components/ReviewForm/useReviewVideoUploader", () => ({
  useReviewVideoUploader: () => ({ error: null, readyToUpload: false, evaporateUploader: null, s3UploadConfig: null }),
}));

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy({}, { get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}` }),
  });
});

afterEach(() => {
  cleanup();
  mocks.setProductRating.mockReset();
});

const review = (message: string) => ({
  id: "r1",
  anonymous: false,
  account_name: "Reviewer",
  rating: 5,
  message,
  purchase_id: "p1",
  purchase_email_digest: "digest",
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
  video: null,
});

const renderPage = (message: string) => {
  const initial = review(message);
  return render(
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
        <ReviewsIndex reviews={[initial]} purchases={[]} />
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );
};

describe("ReviewsIndex", () => {
  it("anchors the edit popover to a definite width instead of the reviewer's quote", () => {
    renderPage("A long review that would otherwise stretch the popover to the viewport cap. ".repeat(20));
    fireEvent.click(screen.getByLabelText("Edit"));

    // happy-dom has no layout, so pin the resolved class list: `cn` must drop the component's `w-max`.
    const popover = document.querySelector('[class*="w-[min(28rem,calc(100vw-2rem))]"]');
    expect(popover).not.toBeNull();
    expect(popover?.classList.contains("w-max")).toBe(false);
  });

  it("closes the edit popover after the review is saved", async () => {
    mocks.setProductRating.mockResolvedValue({ anonymous: false, rating: 5, message: "Updated review", video: null });
    renderPage("Original review");

    fireEvent.click(screen.getByLabelText("Edit"));
    expect(screen.getAllByRole("button", { name: "Edit" })).toHaveLength(2);

    fireEvent.click(screen.getByText("Edit"));
    fireEvent.click(screen.getByRole("button", { name: "Update review" }));

    await waitFor(() => expect(screen.getAllByRole("button", { name: "Edit" })).toHaveLength(1));
    expect(screen.getByText('"Updated review"')).toBeTruthy();
  });
});
