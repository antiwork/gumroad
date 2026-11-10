// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

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
