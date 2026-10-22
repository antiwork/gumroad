// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { saveLastContentPage } from "$app/data/products";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

import { scrollWithinScrollableAncestor } from "./contentPageNavigation";
import { ContentProps, WithContent } from "./WithContent";

const mocks = vi.hoisted(() => ({
  saveLastContentPage: vi.fn(() => Promise.resolve({ success: true })),
}));

// vite.config.ts's `define` replaces the bare `SSR` identifier at build time; vitest doesn't run it.
vi.stubGlobal("SSR", false);

vi.mock("$app/data/products", () => ({
  saveLastContentPage: mocks.saveLastContentPage,
  getFolderArchiveDownloadUrl: vi.fn(),
  getProductFileDownloadInfos: vi.fn(),
}));

// The real Layout renders the product page around the content; this test is about the page list and
// the URL, both of which the layout only has to mount.
vi.mock("$app/components/DownloadPage/Layout", () => ({
  Layout: ({ pageList, children }: { pageList?: React.ReactNode; children: React.ReactNode }) => (
    <div>
      {pageList}
      {children}
    </div>
  ),
}));

vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: vi.fn(() => true) }));

vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useReactNativeMessage", () => ({ useReactNativeMessage: () => {} }));
vi.mock("$app/utils/user_analytics", () => ({ trackSellerPurchaseEvent: vi.fn() }));

vi.mock("./contentPageNavigation", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./contentPageNavigation")>();
  return { ...actual, scrollWithinScrollableAncestor: vi.fn(actual.scrollWithinScrollableAncestor) };
});

const page = (pageId: string, title: string) => ({
  id: pageId,
  page_id: pageId,
  variant_id: null,
  title,
  description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: `${title} body` }] }] },
  updated_at: "2026-10-01T00:00:00Z",
});

const content = (lastContentPageId: string | null): ContentProps => ({
  rich_content_pages: [page("page-a", "Lesson 1"), page("page-b", "Lesson 2"), page("page-c", "Lesson 3")],
  last_content_page_id: lastContentPageId,
  license: null,
  content_items: [],
  bundle_products: [],
  posts: [],
  video_transcoding_info: null,
  custom_receipt: null,
  discord: null,
  ios_app_url: "",
  android_app_url: "",
  download_all_button: null,
  community_chat_url: null,
});

const purchaseProps = () => ({
  id: "purchase-1",
  receipt_purchase_id: null,
  email: "buyer@example.com",
  email_digest: "digest",
  is_archived: false,
  has_invoice: false,
  product_id: "product-1",
  product_permalink: "course",
  product_name: "Course",
  variant_id: null,
  product_long_url: null,
  created_at: "2026-10-01T00:00:00Z",
  allows_review: false,
  product_available: true,
  disable_reviews_after_year: false,
  review: null,
  review_account_name: null,
  membership: null,
  purchase_custom_fields: [],
  call: null,
});

const renderPage = (contentProps: ContentProps, purchase: ReturnType<typeof purchaseProps> | null = purchaseProps()) =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "app.gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gumroad.link",
        discoverDomain: "discover.gumroad.com",
        thirdPartyAnalyticsDomain: "gumroad.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <WithContent
        content={contentProps}
        product_has_third_party_analytics={null}
        seller_analytics={null}
        content_unavailability_reason_code={null}
        is_mobile_app_web_view={false}
        terms_page_url="https://gumroad.com/terms"
        token="token"
        redirect_id="redirect-1"
        add_to_library_option="none"
        purchase={purchase}
      />
    </DomainSettingsProvider>,
  );

const selectedTitle = () =>
  screen.getAllByRole("tab").find((tab) => tab.getAttribute("aria-selected") === "true")?.textContent;

describe("DownloadPage content navigation", () => {
  beforeEach(() => {
    window.history.replaceState(null, "", "/d/token");
    vi.mocked(useIsAboveBreakpoint).mockReturnValue(true);
    mocks.saveLastContentPage.mockClear();
    vi.mocked(scrollWithinScrollableAncestor).mockClear();
  });

  afterEach(() => cleanup());

  // A refresh has to land on the page the buyer was reading, which the URL carries.
  it("opens the page named in the URL", () => {
    window.history.replaceState(null, "", "/d/token?page=page-c");

    renderPage(content(null));

    expect(selectedTitle()).toBe("Lesson 3");
  });

  it("prefers the page in the URL over the page saved on the purchase", () => {
    window.history.replaceState(null, "", "/d/token?page=page-a");

    renderPage(content("page-c"));

    expect(selectedTitle()).toBe("Lesson 1");
  });

  it("falls back to the page saved on the purchase when the URL has none", () => {
    renderPage(content("page-b"));

    expect(selectedTitle()).toBe("Lesson 2");
  });

  it("puts the clicked page in the URL and saves it on the purchase", () => {
    renderPage(content(null));

    fireEvent.click(screen.getByText("Lesson 3"));

    expect(new URL(window.location.href).searchParams.get("page")).toBe("page-c");
    expect(saveLastContentPage).toHaveBeenCalledWith("token", "page-c");
  });

  // The URL is the only copy for a buyer with no purchase behind the link (a guest checkout link),
  // so a refresh for them depends on it entirely.
  it("still remembers the clicked page in the URL without a purchase", () => {
    renderPage(content(null), null);

    fireEvent.click(screen.getByText("Lesson 2"));

    expect(new URL(window.location.href).searchParams.get("page")).toBe("page-b");
    expect(saveLastContentPage).not.toHaveBeenCalled();
  });

  it("scrolls the page list to the page it opened on", () => {
    window.history.replaceState(null, "", "/d/token?page=page-c");

    renderPage(content(null));

    const firstCall = vi.mocked(scrollWithinScrollableAncestor).mock.calls[0];
    expect(firstCall?.[0].dataset.contentPageId).toBe("page-c");
  });

  // On mobile the list lives in a popover that mounts closed, so opening it is the moment the buyer
  // needs the checked page in view.
  it("opens the mobile table of contents on the page it opened on", async () => {
    window.history.replaceState(null, "", "/d/token?page=page-c");
    vi.mocked(useIsAboveBreakpoint).mockReturnValue(false);

    renderPage(content(null));
    vi.mocked(scrollWithinScrollableAncestor).mockClear();

    fireEvent.click(screen.getByLabelText("Table of Contents"));

    await waitFor(() => {
      const items = Array.from(document.querySelectorAll<HTMLElement>("[role=menuitemradio]"));
      expect(items.map((item) => item.getAttribute("aria-checked"))).toEqual(["false", "false", "true"]);
    });

    await waitFor(() => expect(scrollWithinScrollableAncestor).toHaveBeenCalled());
    const firstCall = vi.mocked(scrollWithinScrollableAncestor).mock.calls[0];
    expect(firstCall?.[0].dataset.contentPageId).toBe("page-c");
  });
});
