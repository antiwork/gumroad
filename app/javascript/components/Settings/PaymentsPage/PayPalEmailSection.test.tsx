// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { FormFieldName } from "$app/types/payments";

import PayPalEmailSection from "$app/components/Settings/PaymentsPage/PayPalEmailSection";

const updatePayoutMethod = vi.fn();

const renderSection = (
  overrides: {
    canSetupBankPayouts?: boolean;
    isFormDisabled?: boolean;
    countryCode?: string | null;
    noPayoutRailInCountry?: boolean;
    countryName?: string | null;
  } = {},
) => {
  const {
    canSetupBankPayouts = false,
    isFormDisabled = false,
    countryCode = "IN",
    noPayoutRailInCountry = false,
    countryName = "India",
  } = overrides;
  render(
    <PayPalEmailSection
      canSetupBankPayouts={canSetupBankPayouts}
      showPayPalPayoutsFeeNote={false}
      isFormDisabled={isFormDisabled}
      paypalEmailAddress="seller@example.com"
      setPaypalEmailAddress={() => {}}
      hasConnectedStripe={false}
      feeInfoText=""
      updatePayoutMethod={updatePayoutMethod}
      errorFieldNames={new Set<FormFieldName>()}
      user={{ country_code: countryCode, no_payout_rail_in_country: noPayoutRailInCountry }}
      countryName={countryName}
    />,
  );
};

const switchOption = () => screen.getByRole("button", { name: "Switch to direct deposit" });
const noSwitchOption = () => screen.queryByRole("button", { name: "Switch to direct deposit" });
const indiaExplanation = () => screen.queryByText(/New bank payout accounts cannot be set up in India/u);

beforeEach(() => {
  updatePayoutMethod.mockReset();
  Object.assign(globalThis, { Routes: { help_center_root_path: () => "/help" } });
});
afterEach(cleanup);

describe("bank payout switch option", () => {
  it("offers a working switch where a bank rail can still be set up", () => {
    renderSection({ canSetupBankPayouts: true, countryCode: "US", countryName: "United States" });

    const option = switchOption();
    expect(option.hasAttribute("disabled")).toBe(false);
    expect(indiaExplanation()).toBeNull();

    fireEvent.click(option);
    expect(updatePayoutMethod).toHaveBeenCalledWith("bank");
  });

  it("keeps the switch working for an India seller whose bank account is still active", () => {
    renderSection({ canSetupBankPayouts: true });

    expect(switchOption().hasAttribute("disabled")).toBe(false);
    expect(indiaExplanation()).toBeNull();
  });

  it("shows a disabled option and the country reason for an India seller who cannot set one up", () => {
    renderSection();

    const option = switchOption();
    expect(option.hasAttribute("disabled")).toBe(true);
    expect(indiaExplanation()).toBeTruthy();
    expect(screen.getByRole("link", { name: "Contact support" }).getAttribute("href")).toBe("/help");

    fireEvent.click(option);
    expect(updatePayoutMethod).not.toHaveBeenCalled();
  });

  it("describes the disabled option to assistive tech and drops both link affordances", () => {
    renderSection();

    const option = switchOption();
    expect(option.className).toContain("disabled:cursor-not-allowed");
    expect(option.className).toContain("disabled:no-underline");
    expect(document.getElementById(option.getAttribute("aria-describedby") ?? "")?.textContent).toMatch(
      /New bank payout accounts cannot be set up in India/u,
    );
  });

  it("carries the reason in a status alert rather than muted helper text, and keeps support underlined", () => {
    renderSection();

    const explanation = document.getElementById(switchOption().getAttribute("aria-describedby") ?? "");
    expect(explanation?.getAttribute("role")).toBe("status");
    expect(explanation?.tagName).not.toBe("SMALL");
    expect(explanation?.className).not.toContain("text-muted");

    const support = screen.getByRole("link", { name: "Contact support" });
    expect(explanation?.contains(support)).toBe(true);
    expect(support.className).toContain("underline");
  });

  // The country reason is true regardless of who is editing, and the control is inert either way.
  it("still explains the country restriction when the form is read-only", () => {
    renderSection({ isFormDisabled: true });

    expect(switchOption().hasAttribute("disabled")).toBe(true);
    expect(indiaExplanation()).toBeTruthy();
  });

  it("leaves an eligible seller's permission restriction unexplained by country copy", () => {
    renderSection({ canSetupBankPayouts: true, isFormDisabled: true });

    expect(noSwitchOption()).toBeNull();
    expect(indiaExplanation()).toBeNull();
  });

  it("leaves unsupported non-India countries with only the existing no-rail warning", () => {
    renderSection({ countryCode: "NG", countryName: "Nigeria", noPayoutRailInCountry: true });

    expect(noSwitchOption()).toBeNull();
    expect(indiaExplanation()).toBeNull();
    expect(screen.getByText(/PayPal does not let accounts registered in Nigeria receive money/u)).toBeTruthy();
  });

  it("shows nothing extra when no compliance country is on file", () => {
    renderSection({ countryCode: null, countryName: null });

    expect(noSwitchOption()).toBeNull();
    expect(indiaExplanation()).toBeNull();
  });
});
