// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ErrorLineItemResult } from "$app/data/purchase";

import { LineItemResultEntry } from "$app/components/Checkout/Receipt";
import { DomainSettingsProvider } from "$app/components/DomainSettings";

const domains = {
  scheme: "https",
  appDomain: "app.example.com",
  rootDomain: "example.com",
  shortDomain: "short.example.com",
  discoverDomain: "discover.example.com",
  thirdPartyAnalyticsDomain: "analytics.example.com",
  apiDomain: "api.example.com",
};

const failedResult = (overrides: Partial<Extract<ErrorLineItemResult, { error_code: string | null }>> = {}) =>
  ({
    success: false,
    error_message: "The transaction could not complete.",
    name: "Free download",
    formatted_price: null,
    error_code: "product_temporarily_blocked",
    is_tax_mismatch: false,
    card_country: null,
    ip_country: null,
    updated_product: null,
    ...overrides,
  }) satisfies ErrorLineItemResult;

const renderEntry = (result: ErrorLineItemResult) =>
  render(
    <DomainSettingsProvider value={domains}>
      <LineItemResultEntry name="Free download" result={result} />
    </DomainSettingsProvider>,
  );

describe("LineItemResultEntry for a failed line item", () => {
  beforeEach(() => {
    vi.stubGlobal("Routes", {
      login_url: ({ host, next }: { host: string; next: string }) =>
        `https://${host}/login?next=${encodeURIComponent(next)}`,
    });
    window.history.replaceState({}, "", "/checkout?cart=1");
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("keeps the generic message and offers the sign-in remedy when the server flags it", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: true }));

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.getByText(/Testing your own product\?/u)).toBeTruthy();
    const link = screen.getByRole<HTMLAnchorElement>("link", { name: "Sign in" });
    expect(link.getAttribute("href")).toBe(
      `https://app.example.com/login?next=${encodeURIComponent(window.location.href)}`,
    );
  });

  it("opens the sign-in link in the top window so a framed checkout can keep the login cookie", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: true }));

    expect(screen.getByRole<HTMLAnchorElement>("link", { name: "Sign in" }).getAttribute("target")).toBe("_top");
  });

  it("shows only the generic message when the server does not flag the remedy", () => {
    renderEntry(failedResult());

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.queryByText(/Testing your own product\?/u)).toBeNull();
    expect(screen.queryByRole("link", { name: "Sign in" })).toBeNull();
  });

  it("shows only the generic message when the remedy flag is false", () => {
    renderEntry(failedResult({ owner_sign_in_remedy: false }));

    expect(screen.queryByRole("link", { name: "Sign in" })).toBeNull();
  });

  it("leaves an unrelated risk error without the remedy", () => {
    renderEntry(failedResult({ error_code: "blocked_email_domain" }));

    expect(screen.getByText("The transaction could not complete.")).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Sign in" })).toBeNull();
  });
});
