// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { afterEach, beforeAll, expect, it, vi } from "vitest";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ProductEditContext, type Product } from "$app/components/ProductEdit/state";

vi.mock("$app/components/RichTextEditor", () => ({
  useImageUploadSettings: () => null,
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: {
      edit_link_path: (permalink: string) => `/products/${permalink}/edit`,
      short_link_url: (permalink: string) => `https://seller.gumroad.com/l/${permalink}`,
      settings_payments_path: () => "/settings/payments",
      new_email_path: () => "/emails/new",
      custom_domain_coffee_url: () => "https://seller.gumroad.com/coffee",
    },
  });
});

afterEach(cleanup);

const seller: CurrentSeller = {
  id: "seller-id",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller.gumroad.com",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "UTC", offset: 0 },
  has_published_products: true,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: true,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const publishedProduct = {
  name: "Published product",
  is_published: true,
  native_type: "digital",
  public_files: [],
  files: [],
} as unknown as Product;

const renderHeader = ({ saving, saveStatus }: { saving: boolean; saveStatus: "saved" | "unsaved" | "saving" }) => {
  const save = vi.fn(async () => true);
  const router = createMemoryRouter(
    [
      {
        path: "/",
        handle: "share",
        element: (
          <DomainSettingsProvider
            value={{
              scheme: "https",
              appDomain: "gumroad.com",
              rootDomain: "gumroad.com",
              shortDomain: "gum.co",
              discoverDomain: "gumroad.com",
              thirdPartyAnalyticsDomain: "gumroad.com",
              apiDomain: "gumroad.com",
            }}
          >
            <CurrentSellerProvider value={seller}>
              <ProductEditContext.Provider
                value={
                  {
                    product: publishedProduct,
                    uniquePermalink: "demo",
                    updateProduct: () => undefined,
                    saving,
                    saveStatus,
                    save,
                    receiptEmailFrom: "seller@example.com",
                  } as never
                }
              >
                <Layout>editor</Layout>
              </ProductEditContext.Provider>
            </CurrentSellerProvider>
          </DomainSettingsProvider>
        ),
      },
    ],
    { initialEntries: ["/"] },
  );
  render(<RouterProvider router={router} />);
  return save;
};

it("keeps the Save changes label and disables it once everything is persisted", () => {
  renderHeader({ saving: false, saveStatus: "saved" });

  const save = screen.getByRole("button", { name: "Save changes" });
  expect(save.hasAttribute("disabled")).toBe(true);
  expect(screen.queryByRole("button", { name: "Saving changes..." })).toBeNull();
  expect(screen.getByText("All changes saved")).toBeTruthy();
});

it("keeps Save changes labeled while a save is in flight", () => {
  renderHeader({ saving: true, saveStatus: "saving" });

  const save = screen.getByRole("button", { name: "Save changes" });
  expect(save.hasAttribute("disabled")).toBe(true);
  expect(save.className).toContain("disabled:opacity-100");
  expect(screen.queryByRole("button", { name: "Saving changes..." })).toBeNull();
  expect(screen.getByText("Saving...")).toBeTruthy();
});

it("enables Save changes only while there are unsaved edits", () => {
  renderHeader({ saving: false, saveStatus: "unsaved" });

  expect(screen.getByRole("button", { name: "Save changes" }).hasAttribute("disabled")).toBe(false);
  expect(screen.getByText("Unsaved changes")).toBeTruthy();
});
