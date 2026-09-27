// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PoweredByFooter } from "$app/components/PoweredByFooter";

vi.stubGlobal("Routes", { root_url: () => "https://example.com" });
vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props: {} }) }));
vi.mock("$app/components/DomainSettings", () => ({
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/Logo", () => ({ Logo: () => null }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  document.documentElement.style.removeProperty("--product-cta-bar-height");
});

// The reservation resolves the height the product bar publishes. happy-dom computes no CSS, so the
// resolved geometry is verified in the browser instead (see the PR's mobile evidence).
const reservation = () => {
  const footer = document.querySelector("footer");
  const element = footer?.lastElementChild instanceof HTMLElement ? footer.lastElementChild : null;
  expect(element?.getAttribute("aria-hidden")).toBe("true");
  return element?.className ?? "";
};

describe("PoweredByFooter", () => {
  it("reserves the product bar's published height at the end of the page", () => {
    document.documentElement.style.setProperty("--product-cta-bar-height", "117px");
    render(<PoweredByFooter currencySelector />);

    expect(reservation()).toContain("h-[var(--product-cta-bar-height,0px)]");
    expect(screen.getByLabelText("Currency")).toBeTruthy();
  });

  it("keeps the reservation out of the sm+ row so it stacks below the currency selector", () => {
    render(<PoweredByFooter currencySelector />);

    const row = document.querySelector("footer .sm\\:flex-row");
    expect(row?.contains(screen.getByLabelText("Currency"))).toBe(true);
    expect(row?.querySelector("[aria-hidden]")).toBeNull();
  });

  it("renders the reservation without the currency selector, which stays opt-in", () => {
    render(<PoweredByFooter />);

    expect(reservation()).toContain("h-[var(--product-cta-bar-height,0px)]");
    expect(screen.queryByLabelText("Currency")).toBeNull();
  });
});
