// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import PublicWidgets from "$app/pages/Public/Widgets";
import { cast } from "$app/utils/cast";

const mocks = vi.hoisted(() => ({ props: {} }));
vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props: mocks.props }) }));
vi.mock("$app/components/Developer/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("$app/hooks/usePersistentExternalScript", () => ({ usePersistentExternalScript: () => undefined }));
vi.mock("$app/components/CurrentSeller", () => ({
  useCurrentSeller: () => ({ id: "seller-id", subdomain: "seller.gumroad.test" }),
}));
vi.mock("$app/components/DomainSettings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/DomainSettings")>()),
  useDomains: () => ({}),
  useAppDomain: () => "gumroad.test",
}));

const product = {
  name: "Ebook",
  script_base_url: "https://gumroad.test",
  analytics_script_token: "token",
  url: "https://seller.gumroad.test/l/ebook",
  gumroad_domain_url: "https://gumroad.test/l/ebook",
};

const renderPage = (waitlistProducts: { id: string; name: string }[]) => {
  mocks.props = {
    default_product: product,
    display_product_select: false,
    products: [product],
    affiliated_products: [],
    waitlist_products: waitlistProducts,
  };
  render(<PublicWidgets />);
};

const embedCode = () => cast<HTMLTextAreaElement>(screen.getByLabelText("Subscribe form embed code")).value;

beforeEach(() => {
  Object.assign(globalThis, {
    Routes: {
      custom_domain_subscribe_url: () => "https://seller.gumroad.test/subscribe",
      follow_user_from_embed_form_url: () => "https://gumroad.test/follow_from_embed_form",
    },
  });
});
afterEach(cleanup);

describe("Subscribe form waitlist switch", () => {
  it("adds the chosen waitlist product to the embed code only while it is on", () => {
    renderPage([
      { id: "first", name: "Upcoming course" },
      { id: "second", name: "Second course" },
    ]);

    const toggle = cast<HTMLInputElement>(screen.getByRole("switch", { name: "Also add signups to a waitlist" }));
    expect(toggle.checked).toBe(false);
    const details = toggle.closest("details");
    expect(details?.open).toBe(false);
    expect(embedCode()).not.toContain('name="product_id"');

    fireEvent.click(toggle);
    expect(details?.open).toBe(true);
    const select = cast<HTMLSelectElement>(screen.getByRole("combobox", { name: "Waitlist product" }));
    expect(select.value).toBe("first");
    expect(screen.queryByRole("option", { name: "No waitlist" })).toBeNull();
    expect(document.getElementById(select.getAttribute("aria-describedby") ?? "")?.textContent).toBe(
      "Everyone who signs up still subscribes to you.",
    );
    expect(embedCode()).toContain('name="product_id" value="first"');

    fireEvent.change(select, { target: { value: "second" } });
    expect(embedCode()).toContain('name="product_id" value="second"');

    fireEvent.click(toggle);
    expect(toggle.checked).toBe(false);
    expect(details?.open).toBe(false);
    expect(embedCode()).not.toContain('name="product_id"');
  });
});
