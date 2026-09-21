// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { FormFieldName } from "$app/types/payments";

import PayPalEmailSection from "$app/components/Settings/PaymentsPage/PayPalEmailSection";

const updatePayoutMethod = vi.fn();
const onSubmit = vi.fn((event: React.FormEvent) => event.preventDefault());

const renderSection = (
  overrides: {
    canSetupBankPayouts?: boolean;
    isFormDisabled?: boolean;
    countryCode?: string | null;
    noPayoutRailInCountry?: boolean;
    countryName?: string | null;
    inForm?: boolean;
  } = {},
) => {
  const {
    canSetupBankPayouts = false,
    isFormDisabled = false,
    countryCode = "IN",
    noPayoutRailInCountry = false,
    countryName = "India",
    inForm = false,
  } = overrides;
  const section = (
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
    />
  );
  render(
    inForm ? (
      <form aria-label="Payouts" onSubmit={onSubmit}>
        <input type="text" aria-label="PayPal email" />
        {section}
      </form>
    ) : (
      section
    ),
  );
};

const switchOption = () => screen.getByRole("button", { name: "Switch to direct deposit" });
const noSwitchOption = () => screen.queryByRole("button", { name: "Switch to direct deposit" });
const indiaExplanation = () =>
  screen.queryByText(
    /Switching to direct deposit is unavailable because new bank payout accounts cannot be set up in India/u,
  );
const payoutsLink = () => screen.queryByRole("link", { name: "Learn about payouts" });

beforeEach(() => {
  updatePayoutMethod.mockReset();
  onSubmit.mockReset();
  Object.assign(globalThis, {
    Routes: {
      help_center_root_path: () => "/help",
      help_center_article_path: (slug: string) => `/help/article/${slug}`,
    },
  });
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

  it("replaces the option with the country reason for an India seller who cannot set one up", () => {
    renderSection();

    expect(noSwitchOption()).toBeNull();
    expect(indiaExplanation()).toBeTruthy();
  });

  it("offers a payouts help article instead of a control that cannot do anything", () => {
    renderSection();

    const link = payoutsLink();
    expect(link?.getAttribute("href")).toBe("/help/article/13-getting-paid");
    // Reading it must not cost the seller the PayPal address they were part-way through typing.
    expect(link?.getAttribute("target")).toBe("_blank");
    expect(link?.getAttribute("rel")).toBe("noreferrer");
  });

  it("does not send the seller to the help homepage or a contact form", () => {
    renderSection();

    expect(screen.queryByRole("link", { name: "Contact support" })).toBeNull();
    expect(
      screen
        .getAllByRole("link")
        .map((link) => link.getAttribute("href"))
        .filter((href) => href === "/help"),
    ).toEqual([]);
  });

  it("promises no restoration and assumes no previous bank account", () => {
    renderSection();

    const notice = indiaExplanation();
    expect(notice?.textContent).not.toMatch(/previous bank|again|restor|reinstat|for now|at this time|yet/iu);
  });

  it("carries the reason and its link in one status alert", () => {
    renderSection();

    const alert = screen.getByRole("status");
    expect(alert.textContent).toMatch(/new bank payout accounts cannot be set up in India/u);
    expect(alert.contains(payoutsLink())).toBe(true);
    expect(alert.className).not.toContain("text-muted");
  });

  // The country reason is true regardless of who is editing.
  it("still explains the country restriction when the form is read-only", () => {
    renderSection({ isFormDisabled: true });

    expect(noSwitchOption()).toBeNull();
    expect(indiaExplanation()).toBeTruthy();
    expect(payoutsLink()).toBeTruthy();
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

describe("bank payout switch keyboard semantics", () => {
  it("keeps the working option focusable and activates it without submitting the form", () => {
    renderSection({ canSetupBankPayouts: true, countryCode: "US", countryName: "United States", inForm: true });

    const option = switchOption();
    option.focus();
    expect(document.activeElement).toBe(option);

    // What Enter and Space dispatch on a focused native button. `type="button"` is what keeps it
    // out of the form's default-submit path; `LinkButton.test.tsx` covers that contract directly.
    expect(option.getAttribute("type")).toBe("button");
    fireEvent.click(option, { detail: 0 });

    expect(updatePayoutMethod).toHaveBeenCalledWith("bank");
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("leaves no unavailable bank action for the keyboard to reach", () => {
    renderSection({ inForm: true });

    expect(noSwitchOption()).toBeNull();
    expect(screen.queryByRole("button", { name: /direct deposit|bank/iu })).toBeNull();
    expect(updatePayoutMethod).not.toHaveBeenCalled();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("keeps the payouts article reachable by keyboard from inside the notice", () => {
    renderSection({ inForm: true });

    const link = payoutsLink();
    link?.focus();
    expect(document.activeElement).toBe(link);
    expect(screen.getByRole("status").contains(link)).toBe(true);

    // A link, not a submit button: activating it must not post the payouts form.
    fireEvent.click(link ?? document.body, { detail: 0 });
    expect(onSubmit).not.toHaveBeenCalled();
    expect(updatePayoutMethod).not.toHaveBeenCalled();
  });
});
