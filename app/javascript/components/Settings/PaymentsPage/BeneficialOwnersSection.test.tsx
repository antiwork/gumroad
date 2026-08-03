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
  relationship: { owner: true, director: true, executive: true, representative: false, title: null, percent_ownership: 25 },
  id_number_provided: false,
  ssn_last_4_provided: false,
  nationality: null,
  verification_status: "unverified",
  requirements_currently_due: ["dob.day", "dob.month", "dob.year", "address.line1", "relationship.title"],
};

const renderSection = (owners: unknown[]) => {
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
      countries={{ GB: "United Kingdom" }}
      states={{ us: [], ca: [], au: [], mx: [], ae: [], ir: [], br: [], jp: [] }}
      defaultCountry="GB"
      minDobYear={1900}
      isFormDisabled={false}
    />,
  );
};

const idNumberInput = () => screen.getByLabelText(/tax ID number|ID number/iu);

describe("BeneficialOwnersSection ID number requirement", () => {
  // The server requires an ID number only when creating an owner
  // (StripeBeneficialOwnersManager::REQUIRED_CREATE_ONLY_FIELDS), so requiring it on edit blocked a
  // save the server would have accepted and stranded the seller in a verification loop
  // (gumroad-private#1776).
  it("does not require an ID number when editing an owner who has none on file", async () => {
    renderSection([ownerWithoutIdNumber]);

    fireEvent.click(await screen.findByRole("button", { name: "Edit Chloe Flexman" }));

    await waitFor(() => expect(idNumberInput()).not.toBeRequired());
  });

  it("still requires an ID number when adding a new owner", async () => {
    renderSection([]);

    fireEvent.click(await screen.findByRole("button", { name: /add owner/iu }));

    await waitFor(() => expect(idNumberInput()).toBeRequired());
  });
});
