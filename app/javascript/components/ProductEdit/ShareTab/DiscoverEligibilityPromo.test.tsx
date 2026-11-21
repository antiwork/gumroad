// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { DiscoverEligibilityPromo } from "$app/components/ProductEdit/ShareTab/DiscoverEligibilityPromo";

const promo = () => screen.queryByText(/To appear on Gumroad Discover/u);
const close = () => fireEvent.click(screen.getByRole("button", { name: "Close" }));

describe("DiscoverEligibilityPromo", () => {
  afterEach(() => {
    cleanup();
    localStorage.clear();
  });

  it("hides the promo for the visit only when closed on an unpublished product", () => {
    render(<DiscoverEligibilityPromo rememberDismissal={false} />);
    close();
    expect(promo()).toBeNull();
    cleanup();

    render(<DiscoverEligibilityPromo rememberDismissal />);
    expect(promo()).not.toBeNull();
  });

  it("keeps the promo hidden once closed on a published product", () => {
    render(<DiscoverEligibilityPromo rememberDismissal />);
    close();
    expect(promo()).toBeNull();
    cleanup();

    render(<DiscoverEligibilityPromo rememberDismissal={false} />);
    expect(promo()).toBeNull();
  });
});

it("displays and dismisses the promo when local storage is unavailable", () => {
  const unavailable = () => {
    throw new DOMException("Storage unavailable", "SecurityError");
  };
  vi.stubGlobal("localStorage", { getItem: unavailable, setItem: unavailable });
  try {
    render(<DiscoverEligibilityPromo rememberDismissal />);
    expect(promo()).not.toBeNull();
    close();
    expect(promo()).toBeNull();
  } finally {
    vi.unstubAllGlobals();
    cleanup();
  }
});

it("dismisses the promo for the visit when the dismissal cannot be saved", () => {
  const store: Record<string, string> = {};
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store[key] ?? null,
    setItem: () => {
      throw new DOMException("Quota exceeded", "QuotaExceededError");
    },
  });
  try {
    render(<DiscoverEligibilityPromo rememberDismissal />);
    expect(promo()).not.toBeNull();
    close();
    expect(promo()).toBeNull();
  } finally {
    vi.unstubAllGlobals();
    cleanup();
  }
});
