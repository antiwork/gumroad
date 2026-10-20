// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { trackUserProductAction } from "$app/data/user_action_event";

import { LONG_TITLE_LENGTH, Product, type Product as ProductData, type Purchase } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { Layout } from "$app/components/Product/Layout";

const selectionFlags = vi.hoisted(() => ({
  hasRentOption: false,
  hasMultipleRecurrences: false,
  hasConfigurableQuantity: false,
}));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
});

vi.mock("$app/utils/classNames", () => ({
  classNames: (...xs: unknown[]) => xs.filter((x): x is string => typeof x === "string" && x.length > 0).join(" "),
}));
vi.mock("$app/data/user_action_event", () => ({ trackUserProductAction: vi.fn().mockResolvedValue(undefined) }));
vi.mock("$app/data/view_event", () => ({ incrementProductViews: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({
  startTrackingForSeller: vi.fn(),
  trackBuyerCurrencyDisplayView: vi.fn(),
  trackProductEvent: vi.fn(),
}));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/RichTextEditor", () => ({ useRichTextEditor: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://example.com/products/bundle",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
vi.mock("$app/components/Product/ConfigurationSelector", () => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return {
    ConfigurationSelector,
    applySelection: (product: ProductData) => ({
      basePriceCents: product.price_cents,
      priceCents: product.price_cents,
      discountedPriceCents: product.price_cents,
      pppDiscounted: false,
      isPWYW: false,
      maxQuantity: null,
      selectedOption: null,
      ...selectionFlags,
    }),
    buyerLocalPriceCentsForSelection: (priceCents?: number) => priceCents,
    buyerLocalContextFor: (product: ProductData) => ({
      currencyCode: product.currency_code,
      buyerCurrency: product.buyer_currency,
      buyerLocalCurrencyRate: product.buyer_local_currency_rate,
      buyerLocalCurrencySubunitToUnit: product.buyer_local_currency_subunit_to_unit,
    }),
    withConfiguredOncePerCartAmount: (discount: unknown) => discount,
  };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const selection: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
};

const product: ProductData = {
  id: "bundle",
  name: "Bundle",
  seller: {
    id: "seller",
    name: "Measure Twice Digital With A Very Long Creator Name",
    avatar_url: "https://example.com/avatar.png",
    profile_url: "https://example.com/measure-twice",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/products/bundle",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 1_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "bundle",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: true,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "digital",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: null,
  options: [],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [
    {
      id: "bundle-product",
      name: "Long Bundle Item Name Without SpacesThatUsedToCollapse",
      ratings: { average: 4.8, count: 12 },
      price: 12_345,
      currency_code: "usd",
      thumbnail_url: null,
      native_type: "digital",
      url: "https://example.com/products/item",
      quantity: 1,
      variant: null,
    },
  ],
  public_files: [],
};

describe("long product titles", () => {
  const longName = "A".repeat(LONG_TITLE_LENGTH + 1);
  const renderTitle = (name: string, props: Partial<React.ComponentProps<typeof Product>> = {}) => {
    render(
      <Product product={{ ...product, name }} purchase={null} selection={selection} disableAnalytics {...props} />,
    );
    return screen.getByRole("heading", { level: 1 });
  };

  it("steps a long title down to 32px, and 24px on phones", () => {
    const title = renderTitle(longName);

    expect(title.className).toContain("text-[2rem]");
    expect(title.className).toContain("max-sm:text-[1.5rem]");
  });

  it("keeps a title of exactly the threshold length at the stock size", () => {
    expect(renderTitle("A".repeat(LONG_TITLE_LENGTH)).className).not.toContain("text-[2rem]");
  });

  it("ignores surrounding whitespace when measuring", () => {
    expect(renderTitle(`  ${"A".repeat(LONG_TITLE_LENGTH)}  `).className).not.toContain("text-[2rem]");
  });

  it("leaves the heading at its stock size when the surface opts out", () => {
    expect(renderTitle(longName, { scaleLongTitle: false }).className).not.toContain("text-[2rem]");
  });
});

describe("product page recovery prompt", () => {
  it("places recovery after the main purchase button", () => {
    render(<Product product={product} purchase={null} selection={selection} disableAnalytics />);

    const purchaseButton = screen.getByRole("link", { name: "I want this!" });
    const recoveryLink = screen.getByRole("link", { name: "Get your download link" });
    expect(purchaseButton.compareDocumentPosition(recoveryLink) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
    expect(purchaseButton.closest("section")).toBe(recoveryLink.closest("section"));
  });

  it("tracks recovery without blocking navigation", () => {
    render(<Product product={product} purchase={null} selection={selection} />);

    const recoveryLink = screen.getByRole("link", { name: "Get your download link" });
    expect(fireEvent.click(recoveryLink)).toBe(true);
    expect(trackUserProductAction).toHaveBeenCalledExactlyOnceWith({
      name: "product_purchase_recovery_click",
      permalink: product.permalink,
      keepalive: true,
    });
  });

  it("does not track recovery in a preview with analytics disabled", () => {
    render(<Product product={product} purchase={null} selection={selection} disableAnalytics />);

    fireEvent.click(screen.getByRole("link", { name: "Get your download link" }));
    expect(trackUserProductAction).not.toHaveBeenCalled();
  });

  it.each([
    [false, false, "Get your download link"],
    [true, false, "View your information"],
    [false, true, null],
    [true, true, null],
  ] as const)("handles is_licensed=%s and can_edit=%s", (is_licensed, can_edit, label) => {
    render(
      <Product
        product={{ ...product, is_licensed, can_edit }}
        purchase={null}
        selection={selection}
        disableAnalytics
      />,
    );

    if (label) {
      expect(screen.getByText("Already bought this?")).toBeTruthy();
      expect(screen.getByRole("link", { name: label }).getAttribute("href")).toBe(
        "https://example.com/license-key-lookup",
      );
    } else {
      expect(screen.queryByText("Already bought this?")).toBeNull();
    }
  });
});

describe("product page sticky CTA readiness", () => {
  const renderLayout = (p: ProductData) => {
    class FakeIntersectionObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);

    render(
      <Layout
        product={p}
        purchase={null}
        discount_code={null}
        wishlists={[]}
        main_section_index={0}
        sections={[]}
        creator_profile={{
          external_id: "seller",
          name: "Measure Twice Digital",
          avatar_url: "https://example.com/avatar.png",
          twitter_handle: null,
          subdomain: null,
          is_verified: false,
          can_edit: false,
        }}
        currency_code="usd"
      />,
    );

    return screen.getByRole("region", { name: "Product information bar" });
  };

  const option = (id: string): ProductData["options"][number] => ({
    id,
    name: id,
    quantity_left: null,
    description: "",
    price_difference_cents: 0,
    recurrence_price_values: null,
    is_pwyw: false,
    duration_in_minutes: null,
  });

  // The bar mirrors the in-page CTA's validation: it holds the click back only while the buyer still
  // owes the page a choice. Rent/quantity/recurrence controls being present is not a missing choice —
  // intercepting for those is what made bar taps feel dead before this change.
  it("navigates for a rent-or-buy, quantity-enabled product with nothing left to choose", () => {
    selectionFlags.hasRentOption = true;
    selectionFlags.hasConfigurableQuantity = true;

    const bar = renderLayout(product);
    const cta = within(bar).getByRole("link", { name: "I want this!" });

    expect(fireEvent.click(cta)).toBe(true);
  });

  it("holds the click back and relabels while an option is unchosen", () => {
    selectionFlags.hasMultipleRecurrences = true;

    const bar = renderLayout({ ...product, options: [option("standard"), option("deluxe")] });
    const cta = within(bar).getByRole("link", { name: "Choose an option" });

    expect(fireEvent.click(cta)).toBe(false);
  });

  it("lets the bar through when every option is sold out", () => {
    const soldOut = {
      ...product,
      options: [
        { ...option("standard"), quantity_left: 0 },
        { ...option("deluxe"), quantity_left: 0 },
      ],
    };

    const bar = renderLayout(soldOut);
    const cta = within(bar).getByRole("link", { name: "I want this!" });

    expect(fireEvent.click(cta)).toBe(true);
  });

  afterEach(() => {
    selectionFlags.hasRentOption = false;
    selectionFlags.hasMultipleRecurrences = false;
    selectionFlags.hasConfigurableQuantity = false;
  });
});

describe("product page bundle mobile layout", () => {
  it("renders mobile-safe price/seller and bundle item columns", () => {
    render(<Product product={product} purchase={null} selection={selection} disableAnalytics />);

    const seller = product.seller;
    if (!seller) throw new Error("expected a seller");
    const sellerLink = screen.getByRole("link", { name: seller.name });
    const summarySection = sellerLink.closest("section");
    expect(summarySection?.className.split(" ")).toEqual(expect.arrayContaining(["grid", "grid-cols-1"]));
    expect(summarySection?.className).not.toContain("grid-cols-[auto_1fr]");

    const bundleProduct = product.bundle_products[0];
    if (!bundleProduct) throw new Error("expected a bundle product");
    const bundleLink = screen.getByRole("link", { name: bundleProduct.name });
    const bundleItem = bundleLink.closest('[role="listitem"]');
    if (!bundleItem) throw new Error("expected a bundle list item");
    expect(bundleItem.querySelector("figure")?.className.split(" ")).toEqual(
      expect.arrayContaining(["h-16", "w-16", "shrink-0", "sm:h-28", "sm:w-28"]),
    );
    expect(bundleLink.closest("section")?.className.split(" ")).toEqual(expect.arrayContaining(["min-w-2/5"]));

    const bundlePrice = bundleItem.querySelector(".current-price");
    expect(bundlePrice?.className.split(" ")).toEqual(expect.arrayContaining(["current-price", "whitespace-nowrap"]));
    expect(bundlePrice?.closest("section")?.className.split(" ")).toEqual(
      expect.arrayContaining(["max-w-1/2", "shrink-0", "flex-row", "items-start"]),
    );

    // wrap-break-word is overflow-wrap: break-word; break-words is deprecated in Tailwind v4.1.
    expect(bundleLink.querySelector("h4")?.className.split(" ")).toEqual(expect.arrayContaining(["wrap-break-word"]));
    expect(screen.getByRole("heading", { name: product.name }).className.split(" ")).toEqual(
      expect.arrayContaining(["wrap-break-word"]),
    );

    const priceTag = document.querySelector("[itemprop='price']");
    expect(priceTag?.className.split(" ")).toEqual(expect.arrayContaining(["whitespace-nowrap"]));
    expect(priceTag?.closest("[itemprop='offers']")?.className.split(" ")).toEqual(
      expect.arrayContaining(["flex", "shrink-0"]),
    );

    const cta = screen.getByRole("link", { name: "I want this!" });
    expect(cta.className.split(" ")).toEqual(expect.arrayContaining(["whitespace-nowrap", "shrink-0"]));
  });

  it("keeps the purchase controls ahead of the details block in document order", () => {
    const { container } = render(<Product product={product} purchase={null} selection={selection} disableAnalytics />);

    const cta = screen.getByRole("link", { name: "I want this!" });
    const details = container.querySelector('[class*="grid-area:details"]');
    if (!details) throw new Error("expected a details block");

    // The stacked layout draws the controls above the details, so the DOM has to match: otherwise
    // Tab reaches the bundle links and Read more first and jumps back up to the buy button.
    expect(cta.compareDocumentPosition(details) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
  });

  it("stacks the sticky CTA bar price above the CTA on narrow screens", () => {
    class FakeIntersectionObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);

    render(
      <Layout
        product={product}
        purchase={null}
        discount_code={null}
        wishlists={[]}
        main_section_index={0}
        sections={[]}
        creator_profile={{
          external_id: "seller",
          name: "Measure Twice Digital",
          avatar_url: "https://example.com/avatar.png",
          twitter_handle: null,
          subdomain: null,
          is_verified: false,
          can_edit: false,
        }}
        currency_code="usd"
      />,
    );

    const bar = screen.getByRole("region", { name: "Product information bar" });
    const inner = bar.querySelector(".max-w-product-page");
    const innerClasses = inner?.className.split(" ");
    expect(innerClasses).toEqual(expect.arrayContaining(["flex", "max-sm:flex-col", "max-sm:items-stretch"]));
    expect(innerClasses).not.toContain("max-sm:flex-wrap");
    expect(bar.querySelector("[itemprop='price']")?.className.split(" ")).toEqual(
      expect.arrayContaining(["whitespace-nowrap"]),
    );
    const cta = within(bar).getByRole("link", { name: "I want this!" });
    expect(cta.className.split(" ")).toEqual(expect.arrayContaining(["whitespace-nowrap", "shrink-0"]));
    const ctaWrap = cta.parentElement;
    expect(ctaWrap?.className.split(" ")).toEqual(
      expect.arrayContaining(["shrink-0", "max-sm:flex-col", "max-sm:items-stretch"]),
    );
    // Price wrapper precedes the CTA wrapper, so a column puts the price on top.
    expect(inner?.firstElementChild?.getAttribute("itemprop")).toBe("offers");
    expect(inner?.lastElementChild).toBe(ctaWrap);
  });
});

describe("product page reading order below lg", () => {
  const receipt: Purchase = {
    id: "purchase",
    email_digest: "",
    created_at: "2020-01-01",
    review: null,
    review_account_name: null,
    should_show_receipt: true,
    was_paid: true,
    is_gift_receiver_purchase: false,
    content_url: "https://example.com/d/content",
    show_view_content_button_on_product_page: true,
    total_price_including_tax_and_shipping: "$10",
    subscription_has_lapsed: false,
    membership: null,
  };

  const renderArticle = (p: ProductData, purchase: Purchase | null) => {
    const { container } = render(<Product product={p} purchase={purchase} selection={selection} disableAnalytics />);
    const article = container.querySelector("article");
    if (!article) throw new Error("expected the product article");
    return article;
  };

  // The stacked template's areas top to bottom, next to the article's areas in DOM (= focus) order.
  const areaOrder = (article: HTMLElement) => {
    const template = article.className.split(" ").find((name) => name.startsWith("[grid-template-areas:"));
    const inDom = [...article.children].flatMap((child) => /\[grid-area:(\w+)\]/u.exec(child.className)?.[1] ?? []);
    const drawn = [...(template?.matchAll(/'(\w+)'/gu) ?? [])].flatMap((match) => match[1] ?? []);
    return { drawn: drawn.filter((area) => inDom.includes(area)), inDom };
  };

  // happy-dom's compareDocumentPosition does not follow source order, so compare document positions.
  const position = (element: Element) => [...document.querySelectorAll("*")].indexOf(element);
  const sellerLink = () => screen.getByRole("link", { name: product.seller?.name ?? "" });

  it("draws and focuses the purchase controls before the details for a new buyer", () => {
    const { drawn, inDom } = areaOrder(renderArticle(product, null));

    expect(inDom).toEqual(drawn);
    expect(inDom.indexOf("controls")).toBeLessThan(inDom.indexOf("details"));
    expect(position(screen.getByRole("link", { name: "I want this!" }))).toBeLessThan(position(sellerLink()));
  });

  it("keeps the new-buyer order when the visitor's purchase has no receipt to show", () => {
    const { drawn, inDom } = areaOrder(renderArticle(product, { ...receipt, should_show_receipt: false }));

    expect(inDom).toEqual(drawn);
    expect(inDom.indexOf("controls")).toBeLessThan(inDom.indexOf("details"));
    expect(position(screen.getByRole("link", { name: "Purchase again" }))).toBeLessThan(position(sellerLink()));
  });

  it.each([
    ["View content", { ...receipt }, () => screen.getByRole("link", { name: "View content" })],
    [
      "the license key",
      { ...receipt, license_key: "LICENSE-KEY-1234" },
      () => screen.getByRole("button", { name: "Copy" }),
    ],
    [
      "Manage membership",
      {
        ...receipt,
        membership: { tier_name: "Standard", tier_description: null, manage_url: "https://example.com/manage" },
      },
      () => screen.getByRole("link", { name: "Manage membership" }),
    ],
    [
      "Restart membership",
      {
        ...receipt,
        subscription_has_lapsed: true,
        membership: { tier_name: "Standard", tier_description: null, manage_url: "https://example.com/manage" },
      },
      () => screen.getByRole("link", { name: "Restart membership" }),
    ],
  ] as const)("keeps %s ahead of Purchase again for a returning buyer", (_, purchase, access) => {
    const { drawn, inDom } = areaOrder(renderArticle({ ...product, bundle_products: [] }, purchase));

    expect(inDom).toEqual(drawn);
    expect(inDom.indexOf("details")).toBeLessThan(inDom.indexOf("controls"));
    expect(position(access())).toBeLessThan(position(screen.getByRole("link", { name: "Purchase again" })));
  });

  it("keeps a bundle owner's access card and bundle contents ahead of Purchase again", () => {
    const { drawn, inDom } = areaOrder(renderArticle(product, receipt));
    const purchaseAgain = position(screen.getByRole("link", { name: "Purchase again" }));

    expect(inDom).toEqual(drawn);
    expect(screen.getByRole("heading", { name: "You've purchased this bundle" })).toBeTruthy();
    expect(position(screen.getByRole("link", { name: "View content" }))).toBeLessThan(purchaseAgain);
    expect(position(screen.getByRole("link", { name: product.bundle_products[0]?.name ?? "" }))).toBeLessThan(
      purchaseAgain,
    );
  });

  it("uses the same desktop grid for new and returning buyers", () => {
    const desktopClasses = (article: HTMLElement) =>
      article.className.split(" ").filter((name) => name.startsWith("lg:"));
    const newBuyer = desktopClasses(renderArticle(product, null));
    cleanup();

    expect(desktopClasses(renderArticle(product, receipt))).toEqual(newBuyer);
  });
});
