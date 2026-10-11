// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import LegalGuardianSection, { type Guardian } from "$app/components/Settings/PaymentsPage/LegalGuardianSection";

const mocks = vi.hoisted(() => ({ request: vi.fn(), showAlert: vi.fn() }));
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request: mocks.request,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.showAlert }));

const guardian: Guardian = {
  id: "g1",
  first_name: "Ana",
  last_name: "Ruiz",
  email: "ana@example.com",
  phone: "555-0100",
  date_of_birth: "1980-01-01",
  street_address: "1 Main St",
  city: "Austin",
  state: null,
  zip_code: "78701",
  country: "US",
  nationality: "US",
  has_individual_tax_id: true,
  accepted_terms: true,
  has_completed_info: true,
};

const renderSection = (onSaved = vi.fn()) => {
  render(
    <LegalGuardianSection
      legalGuardian={{ required: true, unsupported: false, blocking_payouts: true, guardian }}
      sellerCountry="US"
      states={[]}
      isFormDisabled={false}
      onSaved={onSaved}
    />,
  );
  return onSaved;
};

describe("LegalGuardianSection", () => {
  beforeEach(() => vi.stubGlobal("Routes", { settings_guardian_path: () => "/settings/guardians/g1" }));
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    mocks.request.mockReset();
    mocks.showAlert.mockReset();
  });

  it.each([
    ["has no guardian", { success: true }],
    ["has a guardian that is not an object", { guardian: "saved" }],
  ])("reports a save whose response %s as a failure", async (_label, body) => {
    mocks.request.mockResolvedValue(new Response(JSON.stringify(body), { status: 200 }));
    const onSaved = renderSection();

    fireEvent.click(screen.getByRole("button", { name: "Save guardian" }));

    await waitFor(() => expect(mocks.showAlert).toHaveBeenCalledWith("Something went wrong.", "error"));
    expect(onSaved).not.toHaveBeenCalled();
  });

  it("saves when the response carries the guardian", async () => {
    mocks.request.mockResolvedValue(new Response(JSON.stringify({ guardian }), { status: 200 }));
    const onSaved = renderSection();

    fireEvent.click(screen.getByRole("button", { name: "Save guardian" }));

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
  });
});
