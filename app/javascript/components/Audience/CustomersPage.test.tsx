// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { type Customer } from "$app/data/customers";

import CustomersPage from "$app/components/Audience/CustomersPage";
import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { UserAgentProvider } from "$app/components/UserAgent";

vi.mock("$assets/images/placeholders/customers.png", () => ({ default: "customers.png" }));

const recipientCount = vi.hoisted(() => ({ current: 0, fail: false }));

vi.mock("$app/data/installments", () => ({
  getRecipientCount: () => ({
    response: recipientCount.fail
      ? Promise.reject(new Error("unavailable"))
      : Promise.resolve({
          recipient_count: recipientCount.current,
          audience_count: recipientCount.current,
        }),
    cancel: () => undefined,
  }),
}));

vi.mock("@inertiajs/react", () => ({
  router: { visit: () => undefined },
  useRemember: (initial: unknown) => React.useState(initial),
}));

vi.hoisted(() => {
  Object.assign(globalThis, {
    Routes: new Proxy(
      {},
      {
        get: () => () => "/emails/new",
      },
    ),
  });
});

afterEach(cleanup);

const seller: CurrentSeller = {
  id: "seller-1",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "America/Los_Angeles", offset: -420 },
  has_published_products: true,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: true,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const customer = (id: string, email: string): Customer => ({
  id,
  email,
  giftee_email: null,
  is_gift_sender_purchase: false,
  is_gift_receiver_purchase: false,
  is_existing_user: false,
  can_contact: true,
  name: "",
  is_bundle_purchase: false,
  product: { name: "Figma UI Kit", permalink: "figma", native_type: "digital" },
  physical: null,
  shipping: null,
  created_at: "2026-09-27T07:14:00.000Z",
  price: {
    cents: 2900,
    cents_before_offer_code: 2900,
    cents_refundable: 2900,
    currency_type: "usd",
    recurrence: null,
    tip_cents: null,
  },
  quantity: 1,
  discount: null,
  subscription: null,
  is_multiseat_license: false,
  upsell: null,
  referrer: null,
  is_additional_contribution: false,
  ppp: null,
  is_preorder: false,
  affiliate: null,
  call: null,
  commission: null,
  license: null,
  review: null,
  custom_fields: [],
  transaction_url_for_seller: null,
  is_access_revoked: null,
  refunded: false,
  partially_refunded: false,
  chargedback: false,
  paypal_refund_expired: false,
  has_options: false,
  option: null,
  utm_link: null,
});

const renderPage = ({
  customers,
  processingCustomers,
  count,
}: {
  customers: Customer[];
  processingCustomers: Customer[];
  count: number;
}) =>
  render(
    <CurrentSellerProvider value={seller}>
      <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
        <CustomersPage
          product_id="prod-1"
          products={[{ id: "prod-1", permalink: "figma", name: "Figma UI Kit", variants: [] }]}
          currency_type="usd"
          countries={["United States"]}
          can_ping={false}
          show_refund_fee_notice={false}
          license_uses_filter_enabled={false}
          can_send_emails
          customers={customers}
          processing_customers={processingCustomers}
          pagination={null}
          count={count}
        />
      </UserAgentProvider>
    </CurrentSellerProvider>,
  );

describe("Email these customers", () => {
  const sellerTime = (timestamp: string) => {
    const createdAt = new Date(timestamp);
    return createdAt.toLocaleDateString("en-US", {
      day: "numeric",
      month: "short",
      year: createdAt.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
      hour: "numeric",
      minute: "numeric",
      hour12: true,
      timeZone: "America/Los_Angeles",
    });
  };

  it("stays available when a completed buyer is in the filtered set", async () => {
    recipientCount.current = 1;
    renderPage({
      customers: [customer("done-1", "done@example.com")],
      processingCustomers: [customer("proc-1", "processing@example.com")],
      count: 1,
    });

    expect(await screen.findByRole("link", { name: "Email these customers" })).toBeTruthy();
    expect(screen.queryByText(/No completed buyer to email/u)).toBeNull();
  });

  it("stays available when the sales total is empty but the email audience has a buyer", async () => {
    recipientCount.current = 1;
    renderPage({
      customers: [],
      processingCustomers: [],
      count: 0,
    });

    expect((await screen.findByRole("link", { name: "Email these customers" })).getAttribute("href")).toBe(
      "/emails/new",
    );
  });

  it("stays available when a processing sale is visible but the email audience has a buyer", async () => {
    recipientCount.current = 1;
    renderPage({
      customers: [],
      processingCustomers: [customer("proc-1", "processing@example.com")],
      count: 0,
    });

    expect(await screen.findByRole("link", { name: "Email these customers" })).toBeTruthy();
  });

  it("is disabled when the filtered set has only a processing sale", async () => {
    recipientCount.current = 0;
    renderPage({
      customers: [],
      processingCustomers: [customer("proc-1", "processing@example.com")],
      count: 0,
    });

    const time = sellerTime("2026-09-27T07:14:00.000Z");

    expect(await screen.findByRole("button", { name: "Email these customers" })).toHaveProperty("disabled", true);
    expect(screen.queryByRole("link", { name: "Email these customers" })).toBeNull();
    expect(await screen.findByText("No completed buyer to email. This sale is still processing.")).toBeTruthy();
    expect(screen.getByText(time)).toBeTruthy();
    expect(screen.getByText(time).textContent).toContain("12:14 AM");
  });

  it("stays available when the recipient count cannot be loaded", async () => {
    recipientCount.fail = true;
    renderPage({
      customers: [],
      processingCustomers: [customer("proc-1", "processing@example.com")],
      count: 0,
    });

    expect(await screen.findByRole("link", { name: "Email these customers" })).toBeTruthy();
    await Promise.resolve();
    expect(screen.queryByRole("button", { name: "Email these customers" })).toBeNull();
    recipientCount.fail = false;
  });
});
