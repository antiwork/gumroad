// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { cast } from "$app/utils/cast";

import { MarketingEmailStatus } from "$app/components/BundleEdit/ShareTab/MarketingEmailStatus";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it("groups the audience options and updates the recipient filter when the seller picks one", () => {
  const newEmailPath = vi.fn(() => "/emails/new");
  vi.stubGlobal("Routes", { new_email_path: newEmailPath });
  const products = cast<React.ComponentProps<typeof MarketingEmailStatus>["products"]>([
    { permalink: "guide", name: "Guide", price_cents: 1_000, quantity: 1, variants: null },
  ]);
  render(<MarketingEmailStatus id="bundle" isPublished {...(products ? { products } : {})} />);

  const audience = within(screen.getByRole("group", { name: "Email audience" }));
  const bundleBuyers = audience.getByRole<HTMLInputElement>("radio", { name: /purchased at least one product/u });
  const allCustomers = audience.getByRole<HTMLInputElement>("radio", { name: "All customers" });
  expect(bundleBuyers.name).not.toBe("");
  expect(bundleBuyers.name).toBe(allCustomers.name);
  expect(bundleBuyers.checked).toBe(true);
  expect(newEmailPath).toHaveBeenLastCalledWith(expect.objectContaining({ bundle_product_permalinks: ["guide"] }));

  fireEvent.click(allCustomers);
  expect(allCustomers.checked).toBe(true);
  expect(bundleBuyers.checked).toBe(false);
  expect(newEmailPath).toHaveBeenLastCalledWith(expect.objectContaining({ bundle_product_permalinks: undefined }));
});
