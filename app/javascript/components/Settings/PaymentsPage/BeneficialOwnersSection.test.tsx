// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { stripeRequirementLabel } from "$app/utils/personalTaxId";

import BeneficialOwnersSection from "$app/components/Settings/PaymentsPage/BeneficialOwnersSection";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

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

// happy-dom's compareDocumentPosition does not report source order, so read the form controls back
// in the order the DOM actually has them.
const passportFieldsInOrder = (number: HTMLElement, issuingCountry: HTMLElement): HTMLElement[] =>
  Array.from(document.querySelectorAll<HTMLElement>("input, select")).filter(
    (field) => field === number || field === issuingCountry,
  );

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
      countries={{
        GB: "United Kingdom",
        AE: "United Arab Emirates",
        HK: "Hong Kong",
        DO: "Dominican Republic",
        PK: "Pakistan",
      }}
      states={{ us: [], ca: [], au: [], mx: [], ae: [], ir: [], br: [], jp: [] }}
      defaultCountry={defaultCountry}
      minDobYear={1900}
      isFormDisabled={false}
    />,
  );
};

// GB has no country-specific config, so the field carries the fallback "Personal ID number" label.
const idNumberInput = () => screen.getByLabelText("Personal ID number");

describe("Stripe requirement labels", () => {
  it("does not repeat a title that is already listed as a role", async () => {
    renderSection([
      {
        ...ownerWithoutIdNumber,
        relationship: {
          ...ownerWithoutIdNumber.relationship,
          director: false,
          executive: false,
          title: "Owner",
          percent_ownership: 100,
        },
      },
    ]);
    expect(await screen.findByText("Owner · 100%")).toBeTruthy();
    expect(screen.queryByText("Owner · 100% · Owner")).toBeNull();
  });

  it.each([
    ["id_number", "Personal tax ID"],
    ["verification.document", "Identity document"],
    ["ssn_last_4", "Last 4 of SSN"],
    ["dob.day", "Date of birth"],
    ["dob.month", "Date of birth"],
    ["dob.year", "Date of birth"],
    ["address.line1", "Address"],
    ["address.postal_code", "Address"],
    ["relationship.title", "Relationship title"],
    ["verification.additional_document", "Verification additional document"],
  ])("labels %s as %s", (key, label) => expect(stripeRequirementLabel(key)).toBe(label));

  it("renders human labels without duplicate date-of-birth or address requirements", async () => {
    renderSection([
      {
        ...ownerWithoutIdNumber,
        requirements_currently_due: ["id_number", "dob.day", "dob.month", "address.line1", "address.city"],
      },
    ]);
    expect(await screen.findByText("Stripe needs: Personal tax ID, Date of birth, Address")).toBeTruthy();
  });
});

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

    const note = await screen.findByText(
      "Nationals of Cuba, Iran, North Korea and Syria cannot be verified, so their nationalities are not listed.",
    );

    expect(screen.getByLabelText("Nationality").getAttribute("aria-describedby")).toBe(note.id);
  });

  it("does not carry the note for a country that does not ask for nationality", async () => {
    renderSection([], "GB");
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));

    expect(screen.queryByText(/Nationals of Cuba/u)).toBeNull();
  });
});

describe("BeneficialOwnersSection Hong Kong passport", () => {
  const openAddForm = async () => {
    renderSection([], "HK");
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));
    await screen.findByLabelText("Hong Kong ID Number");
  };

  it("keeps the Hong Kong ID number while the owner's address is in Hong Kong", async () => {
    await openAddForm();

    expect(screen.queryByLabelText("Passport issuing country")).toBeNull();
  });

  it("asks for a passport number and issuing country once the address is outside Hong Kong", async () => {
    await openAddForm();

    fireEvent.change(screen.getByLabelText("Country"), { target: { value: "GB" } });

    expect(await screen.findByLabelText("Passport number")).toBeTruthy();
    expect(screen.queryByLabelText("Hong Kong ID Number")).toBeNull();
    expect(screen.getByLabelText<HTMLSelectElement>("Passport issuing country").required).toBe(true);
  });

  it("puts the passport number before the issuing country", async () => {
    await openAddForm();

    fireEvent.change(screen.getByLabelText("Country"), { target: { value: "GB" } });

    const number = await screen.findByLabelText("Passport number");
    const issuingCountry = screen.getByLabelText("Passport issuing country");

    expect(passportFieldsInOrder(number, issuingCountry)).toEqual([number, issuingCountry]);
    expect(within(issuingCountry).getByRole("option", { name: "Select country" })).toBeTruthy();
  });

  it("explains why a passport is asked for under the passport number", async () => {
    await openAddForm();
    expect(
      screen.getByText("We are required to collect this information to satisfy regulatory obligations."),
    ).toBeTruthy();

    fireEvent.change(screen.getByLabelText("Country"), { target: { value: "GB" } });

    expect(
      await screen.findByText(
        "Enter their passport number instead of a Hong Kong ID number, since they live outside Hong Kong.",
      ),
    ).toBeTruthy();
    expect(
      screen.queryByText("We are required to collect this information to satisfy regulatory obligations."),
    ).toBeNull();
  });

  it("explains the omitted countries on the issuing-country note only", async () => {
    await openAddForm();

    fireEvent.change(screen.getByLabelText("Country"), { target: { value: "GB" } });

    const note = await screen.findByText(
      "Nationals of Cuba, Iran, North Korea and Syria cannot be verified, so those countries are not listed.",
    );

    expect(screen.getByLabelText("Passport issuing country").getAttribute("aria-describedby")).toBe(note.id);
  });

  it("does not require the issuing country when editing an owner abroad who has none on file", async () => {
    renderSection([ownerWithoutIdNumber], "HK");
    fireEvent.click(await screen.findByRole("button", { name: "Edit Chloe Flexman" }));

    const select = await screen.findByLabelText<HTMLSelectElement>("Passport issuing country");
    expect(select.required).toBe(false);
  });
});

describe("BeneficialOwnersSection Dominican Republic CIE", () => {
  const cieLabel = "Cédula de identidad y electoral (CIE)";
  const formatError = /must be 13 characters including the dashes/u;
  const savedOwner = { ...ownerWithoutIdNumber, address: { ...ownerWithoutIdNumber.address, country: "DO" } };

  const submittedWrites = () =>
    vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method === "POST" || init?.method === "PUT");

  const submitForm = (input: HTMLElement) => {
    const form = input.closest("form");
    if (!form) throw new Error("The ID number input is not inside a form");
    fireEvent.submit(form);
  };

  const submitWithCie = (value: string) => {
    const input = screen.getByLabelText(cieLabel);
    fireEvent.change(input, { target: { value } });
    submitForm(input);
  };

  const openAddForm = async (defaultCountry = "DO") => {
    renderSection([], defaultCountry);
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));
    await screen.findByLabelText(defaultCountry === "DO" ? cieLabel : "Personal ID number");
  };

  it.each([
    "00112345678",
    "001-12345678",
    "001-1234567-88",
    "P1234567",
    " 001-1234567-8",
    "001-1234567-8 ",
    "001 -1234567-8",
  ])("refuses to add an owner with the malformed CIE %j", async (value) => {
    await openAddForm();

    submitWithCie(value);

    expect(await screen.findByText(formatError)).toBeTruthy();
    expect(submittedWrites()).toHaveLength(0);
  });

  it("adds an owner with a dashed CIE", async () => {
    await openAddForm();

    submitWithCie("001-1234567-8");

    await waitFor(() => expect(submittedWrites()).toHaveLength(1));
    expect(screen.queryByText(formatError)).toBeNull();
  });

  it("refuses to save an edited owner whose new CIE is malformed", async () => {
    renderSection([savedOwner], "DO");
    fireEvent.click(await screen.findByRole("button", { name: "Edit Chloe Flexman" }));

    submitWithCie("00112345678");

    expect(await screen.findByText(formatError)).toBeTruthy();
    expect(submittedWrites()).toHaveLength(0);
  });

  it("saves an edited owner whose CIE field is left blank", async () => {
    renderSection([savedOwner], "DO");
    fireEvent.click(await screen.findByRole("button", { name: "Edit Chloe Flexman" }));

    submitWithCie("");

    await waitFor(() => expect(submittedWrites()).toHaveLength(1));
    expect(screen.queryByText(formatError)).toBeNull();
  });

  it("does not apply the CIE rule to another country's owners", async () => {
    await openAddForm("GB");

    const input = screen.getByLabelText("Personal ID number");
    fireEvent.change(input, { target: { value: "AB123456C" } });
    submitForm(input);

    await waitFor(() => expect(submittedWrites()).toHaveLength(1));
    expect(screen.queryByText(formatError)).toBeNull();
  });
});

describe("BeneficialOwnersSection Pakistan CNIC", () => {
  const cnicLabel = "National Identity Card Number (SNIC or CNIC)";
  const formatError = /Your CNIC must be 13 digits/u;

  const submittedWrites = () =>
    vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method === "POST" || init?.method === "PUT");

  const openAddFormAndSubmit = async (value: string) => {
    renderSection([], "PK");
    fireEvent.click(await screen.findByRole("button", { name: "Add beneficial owner" }));
    const input = await screen.findByLabelText<HTMLInputElement>(cnicLabel);
    fireEvent.change(input, { target: { value } });
    const form = input.closest("form");
    if (!form) throw new Error("The ID number input is not inside a form");
    fireEvent.submit(form);
    return input;
  };

  it("does not cap the field, so a CNIC pasted with spaces is not cut short", async () => {
    const input = await openAddFormAndSubmit(" 12345-1234567-1\u00a0");

    expect(input.hasAttribute("maxlength")).toBe(false);
    expect(input.placeholder).toBe("12345-1234567-1");
    await waitFor(() => expect(submittedWrites()).toHaveLength(1));
    expect(screen.queryByText(formatError)).toBeNull();
  });

  it.each(["P1234512345671", "12345_1234567_1", "12345-1234567"])(
    "refuses to add an owner with the malformed CNIC %j",
    async (value) => {
      await openAddFormAndSubmit(value);

      expect(await screen.findByText(formatError)).toBeTruthy();
      expect(screen.getByText("13 digits, dashes optional")).toBeTruthy();
      expect(submittedWrites()).toHaveLength(0);
    },
  );
});
