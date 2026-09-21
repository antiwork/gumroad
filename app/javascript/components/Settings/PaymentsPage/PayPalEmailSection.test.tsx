// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import PayPalEmailSection from "$app/components/Settings/PaymentsPage/PayPalEmailSection";

afterEach(cleanup);

const renderSection = (canSetupBankPayouts: boolean, isFormDisabled = false) => {
  const updatePayoutMethod = vi.fn();
  render(
    <PayPalEmailSection
      canSetupBankPayouts={canSetupBankPayouts}
      isFormDisabled={isFormDisabled}
      showPayPalPayoutsFeeNote={false}
      paypalEmailAddress="seller@example.com"
      setPaypalEmailAddress={vi.fn()}
      hasConnectedStripe={false}
      feeInfoText=""
      updatePayoutMethod={updatePayoutMethod}
      errorFieldNames={new Set()}
      user={{ country_code: "IN", no_payout_rail_in_country: false }}
      countryName="India"
    />,
  );
  return updatePayoutMethod;
};

const note = "Bank payouts can no longer be set up in this country; contact support if this looks wrong.";

describe("switching from PayPal to direct deposit", () => {
  it("keeps unavailable direct deposit visible, disabled, and explained", () => {
    const updatePayoutMethod = renderSection(false);
    const button = screen.getByRole<HTMLButtonElement>("button", { name: "Switch to direct deposit" });
    expect(button.disabled).toBe(true);
    expect(document.getElementById(button.getAttribute("aria-describedby") ?? "")?.textContent).toBe(note);
    fireEvent.click(button);
    expect(updatePayoutMethod).not.toHaveBeenCalled();
  });

  it("allows switching when bank setup is available regardless of the country name", () => {
    const updatePayoutMethod = renderSection(true);
    const button = screen.getByRole<HTMLButtonElement>("button", { name: "Switch to direct deposit" });
    expect(button.disabled).toBe(false);
    expect(screen.queryByText(note)).toBeNull();
    fireEvent.click(button);
    expect(updatePayoutMethod).toHaveBeenCalledWith("bank");
  });

  it("keeps the switch disabled when the whole form is read-only", () => {
    const updatePayoutMethod = renderSection(true, true);
    const button = screen.getByRole<HTMLButtonElement>("button", { name: "Switch to direct deposit" });
    expect(button.disabled).toBe(true);
    expect(screen.queryByText(note)).toBeNull();
    fireEvent.click(button);
    expect(updatePayoutMethod).not.toHaveBeenCalled();
  });
});
