// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import BeneficialOwnersSection from "$app/components/Settings/PaymentsPage/BeneficialOwnersSection";

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy(
      {},
      {
        get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}`,
      },
    ),
  });
});

afterEach(cleanup);

// A co-director with no ID number on file: exactly the shape Stripe asks us to complete with a DOB,
// an address and a title, and never asks for an ID number for.
const ownerWithoutIdNumber = {
  id: "person_1",
  first_name: "Chloe",
  last_name: "Flexman",
  email: null,
  phone: null,
  dob: { day: null, month: null, year: null },
  address: { line1: null, city: null, postal_code: null, state: null, country: "GB" },
  relationship: {
    owner: true,
    director: true,
    executive: true,
    representative: false,
    title: null,
    percent_ownership: 25,
  },
  id_number_provided: false,
  ssn_last_4_provided: false,
  nationality: null,
  verification_status: "unverified",
  requirements_currently_due: ["dob.day", "dob.month", "dob.year", "address.line1", "relationship.title"],
};

const renderSection = (owners: unknown[], defaultCountry = "GB") => {
  vi.stubGlobal(
    "fetch",
    vi.fn(() =>
      Promise.resolve(
        new Response(JSON.stringify({ beneficial_owners: owners }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      ),
    ),
  );
  return render(
    <BeneficialOwnersSection
      countries={{ GB: "United Kingdom", AE: "United Arab Emirates" }}
      states={{ us: [], ca: [], au: [], mx: [], ae: [], ir: [], br: [], jp: [] }}
      defaultCountry={defaultCountry}
      minDobYear={1900}
      isFormDisabled={false}
    />,
  );
};

// GB has no country-specific config, so the field carries the fallback "Personal ID number" label.
const idNumberInput = () => screen.getByLabelText("Personal ID number");

describe("BeneficialOwnersSection ID number requirement", () => {
  // The server requires an ID number only when creating an owner
  // (StripeBeneficialOwnersManager::REQUIRED_CREATE_ONLY_FIELDS), so requiring it on edit blocked a
  // save the server would have accepted and stranded the seller in a verification loop
  // (gumroad-private#1776).
  it("does not require an ID number when editing an owner who has none on file", async () => {
    renderSection([ownerWithoutIdNumber]);

    fireEvent.click(await screen.findByRole("button", { name: "Edit Chloe Flexman" }));

    await waitFor(() => expect(idNumberInput().hasAttribute("required")).toBe(false));
  });

  it("still requires an ID number when adding a new owner", async () => {
    renderSection([]);

    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));

    await waitFor(() => expect(idNumberInput().hasAttribute("required")).toBe(true));
  });
});

describe("BeneficialOwnersSection nationality note", () => {
  // The select silently omits four nationalities; without this the owner cannot tell that from a bug.
  it("says why the sanctioned nationalities are missing when the field is shown", async () => {
    renderSection([], "AE");
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));

    expect(await screen.findByText(/Nationals of Cuba, Iran, North Korea and Syria/u)).toBeTruthy();
  });

  it("does not carry the note for a country that does not ask for nationality", async () => {
    renderSection([], "GB");
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));

    expect(screen.queryByText(/Nationals of Cuba/u)).toBeNull();
  });
});
