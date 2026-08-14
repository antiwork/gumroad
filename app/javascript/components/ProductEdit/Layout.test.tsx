// @vitest-environment happy-dom
/* eslint-disable @typescript-eslint/consistent-type-assertions -- header stubs a huge Product/context */
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { afterEach, beforeAll, expect, it, vi } from "vitest";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { Layout } from "$app/components/ProductEdit/Layout";
import {
  type ContentUpdates,
  ProductEditContext,
  type Product,
  type SaveStatus,
} from "$app/components/ProductEdit/state";

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

const unpublishedProduct = { ...publishedProduct, is_published: false } as Product;

const renderHeader = ({
  saving,
  saveStatus,
  autosaveEnabled = true,
  contentUpdates = null,
  handle = "share",
  published = true,
}: {
  saving: boolean;
  saveStatus: SaveStatus;
  autosaveEnabled?: boolean;
  contentUpdates?: ContentUpdates;
  handle?: string;
  published?: boolean;
}) => {
  const save = vi.fn(async () => true);
  const router = createMemoryRouter(
    [
      // Navigation target for the wizard's Continue button.
      { path: "/products/demo/edit/content", element: <div /> },
      {
        path: "/",
        handle,
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
                    product: published ? publishedProduct : unpublishedProduct,
                    uniquePermalink: "demo",
                    updateProduct: () => undefined,
                    saving,
                    saveStatus,
                    autosaveEnabled,
                    save,
                    contentUpdates,
                    setContentUpdates: () => undefined,
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

it("enables Save changes and stays quiet while there are unsaved edits", () => {
  renderHeader({ saving: false, saveStatus: "unsaved" });

  expect(screen.getByRole("button", { name: "Save changes" }).hasAttribute("disabled")).toBe(false);
  // Between keystrokes the header shows no status: a ticking
  // Unsaved/Saving/Saved label reads like a warning light.
  expect(screen.queryByText("Unsaved changes")).toBeNull();
});

it("leaves Save changes enabled and hides status when autosave is off", () => {
  renderHeader({ saving: false, saveStatus: "saved", autosaveEnabled: false });

  expect(screen.getByRole("button", { name: "Save changes" }).hasAttribute("disabled")).toBe(false);
  expect(screen.queryByText("All changes saved")).toBeNull();
});

it("opens the deletion review from the status label", () => {
  const save = renderHeader({ saving: false, saveStatus: "review_deletions" });

  const label = screen.getByRole("button", { name: "Save to review deletions" });
  fireEvent.click(label);
  expect(save).toHaveBeenCalled();
});

it("announces only the states that need the seller", () => {
  renderHeader({ saving: false, saveStatus: "failed" });

  // Rendered twice on purpose: the visible muted label and the hidden
  // announcement region.
  expect(screen.getAllByText("Couldn't save changes")).toHaveLength(2);
  expect(screen.getByRole("status").textContent).toBe("Couldn't save changes");
  expect(screen.getByRole("button", { name: "Save changes" }).hasAttribute("disabled")).toBe(false);
});

it("keeps the announcement region empty for routine saves", () => {
  renderHeader({ saving: false, saveStatus: "saved" });

  expect(screen.getByRole("status").textContent).toBe("");
});

it("continues without a redundant save once autosave persisted everything", () => {
  const save = renderHeader({ saving: false, saveStatus: "saved", handle: "product", published: false });

  fireEvent.click(screen.getByRole("button", { name: "Continue" }));
  expect(save).not.toHaveBeenCalled();
});

it("saves before continuing while edits are still pending", () => {
  const save = renderHeader({ saving: false, saveStatus: "unsaved", handle: "product", published: false });

  fireEvent.click(screen.getByRole("button", { name: "Save and continue" }));
  expect(save).toHaveBeenCalled();
});

it("describes an automatic prompt without claiming a click", () => {
  renderHeader({
    saving: false,
    saveStatus: "saved",
    contentUpdates: { uniquePermalinkOrVariantIds: ["demo"], automatic: true },
  });

  expect(screen.getByText(/saved automatically/u)).toBeTruthy();
  expect(screen.queryByText(/Changes saved!/u)).toBeNull();
});
