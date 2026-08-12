// @vitest-environment happy-dom
import { cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterAll, afterEach, beforeAll, expect, it, vi } from "vitest";

import { CurrentSellerProvider } from "$app/components/CurrentSeller";
import { TiersEditor } from "$app/components/ProductEdit/ProductTab/TiersEditor";
import { type Tier } from "$app/components/ProductEdit/state";

const productEditContext = vi.hoisted(() => ({
  product: {
    name: "Membership",
    native_type: "membership",
    subscription_duration: null,
    integrations: {},
  },
  currencyType: "usd",
  setCurrencyType: vi.fn(),
  uniquePermalink: "membership",
  updateProduct:
    vi.fn<
      (
        update: (product: {
          confirmed_removed_variant_ids?: string[];
          confirmed_removed_rich_content_ids?: string[];
        }) => void,
      ) => void
    >(),
  earliestMembershipPriceChangeDate: new Date("2026-08-12T00:00:00.000Z"),
}));

vi.mock("$app/components/ProductEdit/Layout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/ProductEdit/Layout")>()),
  useProductUrl: () => "#",
}));
vi.mock("$app/components/ProductEdit/state", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/ProductEdit/state")>()),
  useProductEditContext: () => productEditContext,
}));
vi.mock("$app/components/RichTextEditor", () => ({ RichTextEditor: () => null }));
vi.mock("$app/components/SortableList", () => ({
  Drawer: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  ReorderingHandle: () => null,
  SortableList: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

beforeAll(() => {
  vi.stubEnv("TZ", "America/Los_Angeles");
});

afterAll(() => {
  vi.unstubAllEnvs();
});

afterEach(cleanup);

const tier: Tier = {
  id: "tier-id",
  name: "Membership",
  description: "",
  max_purchase_count: null,
  integrations: { discord: false, circle: false, google_calendar: false },
  rich_content: [],
  customizable_price: false,
  apply_price_changes_to_existing_memberships: false,
  subscription_price_change_effective_date: "2026-08-12T00:00:00.000Z",
  subscription_price_change_message: null,
  recurrence_price_values: {
    monthly: { enabled: true, price_cents: 1_000, suggested_price_cents: null },
    quarterly: { enabled: false },
    biannually: { enabled: false },
    yearly: { enabled: false },
    every_two_years: { enabled: false },
  },
};

// A newly added tier can be mid-creation by an in-flight save when the seller
// removes it, so its client id must be recorded like any other: the response
// remaps it to the canonical id, and an id the server never learns is inert.
// Skipping it would leave the created tier (and its pages) with no recorded
// deletion intent, and the save-time missing-content guard would block the
// seller's own deletion behind a reload.
it("records a newly added tier's id and its page ids when the seller removes it", () => {
  const onChange = vi.fn<(tiers: Tier[]) => void>();
  const newTier: Tier = {
    ...tier,
    id: "local-new-tier",
    newlyAdded: true,
    rich_content: [{ id: "new-tier-page", title: "Lesson", description: {}, updated_at: "2026-01-01T00:00:00Z" }],
  };
  const view = render(
    <CurrentSellerProvider value={null}>
      <TiersEditor tiers={[newTier]} onChange={onChange} />
    </CurrentSellerProvider>,
  );

  fireEvent.click(view.getByLabelText("Remove"));
  fireEvent.click(view.getByText("Yes, remove"));

  const record = productEditContext.updateProduct.mock.lastCall?.[0];
  expect(record).toBeTypeOf("function");
  const recorded: { confirmed_removed_variant_ids?: string[]; confirmed_removed_rich_content_ids?: string[] } = {};
  record?.(recorded);
  expect(recorded.confirmed_removed_variant_ids).toEqual(["local-new-tier"]);
  expect(recorded.confirmed_removed_rich_content_ids).toEqual(["new-tier-page"]);
  expect(onChange).toHaveBeenCalledWith([]);
});

it("keeps the membership price-change date stable across rerenders", () => {
  const onChange = vi.fn<(tiers: Tier[]) => void>();
  const tree = () => (
    <CurrentSellerProvider value={null}>
      <TiersEditor tiers={[tier]} onChange={onChange} />
    </CurrentSellerProvider>
  );
  const view = render(tree());

  for (let rerender = 0; rerender < 5; rerender++) view.rerender(tree());
  fireEvent.click(view.getByLabelText("Apply price changes to existing customers"));

  expect(onChange.mock.lastCall?.[0]?.[0]?.subscription_price_change_effective_date).toMatch(/^2026-08-12/u);
});
