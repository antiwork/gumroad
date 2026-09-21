// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// Show is imported statically rather than lazily: it pulls in typia plus the whole ui component
// tree, and transforming that graph inside a hook exceeds vitest's default hookTimeout.
import PaymentsPage from "$app/pages/Settings/Payments/Show";
import type { ComplianceInfo, User } from "$app/types/payments";

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  put: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({
  router: { get: vi.fn(), reload: vi.fn(), replace: vi.fn() },
  usePage: mocks.usePage,
  useForm: <T,>(initial: T) => {
    const [data, setDataState] = React.useState(initial);
    const transformRef = React.useRef<(d: T) => unknown>((d) => d);
    return {
      data,
      processing: false,
      // Inertia's setData takes either one field or a partial payload; the country-change reset uses
      // the payload form, which a field-only double drops without failing.
      setData: (key: string | Partial<T>, value?: T[keyof T]) =>
        setDataState((prev) => (typeof key === "object" ? { ...prev, ...key } : { ...prev, [key]: value })),
      transform: (fn: (d: T) => unknown) => {
        transformRef.current = fn;
      },
      put: (url: string) => {
        mocks.put(url, transformRef.current(data));
      },
    };
  },
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy({}, { get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}` }),
  });
});

afterEach(cleanup);
beforeEach(() => {
  mocks.put.mockReset();
});

const user = (overrides: Partial<User> = {}): User => ({
  country_supports_native_payouts: true,
  no_payout_rail_in_country: false,
  country_supports_iban: false,
  need_full_ssn: false,
  country_code: "US",
  payout_currency: "usd",
  is_from_europe: false,
  individual_tax_id_needed_countries: ["US"],
  individual_tax_id_entered: true,
  individual_tax_id_last_four: "6789",
  individual_tax_id_is_last_four: false,
  has_outstanding_full_ssn_requirement: false,
  has_outstanding_nationality_requirement: false,
  business_tax_id_entered: false,
  business_tax_id_last_four: null,
  requires_credit_card: false,
  is_charged_paypal_payout_fee: false,
  joined_at: "2026-01-01",
  ...overrides,
});

const complianceInfo = (overrides: Partial<ComplianceInfo> = {}): ComplianceInfo => ({
  is_business: false,
  business_name: null,
  business_type: null,
  business_street_address: null,
  business_city: null,
  business_state: null,
  business_country: null,
  business_zip_code: null,
  business_phone: null,
  job_title: null,
  first_name: "Test",
  last_name: "Seller",
  street_address: "123 Main St",
  city: "San Francisco",
  state: "CA",
  country: "US",
  zip_code: "94103",
  phone: "+14155552671",
  nationality: null,
  dob_month: 1,
  dob_day: 1,
  dob_year: 2000,
  ...overrides,
});

const pageProps = (userOverrides: Partial<User> = {}, complianceOverrides: Partial<ComplianceInfo> = {}) => ({
  settings_pages: ["payments"],
  is_form_disabled: false,
  should_show_country_modal: false,
  aus_backtax_details: {
    total_amount_to_au: "$0",
    au_backtax_amount: "$0",
    credit_creation_date: "2026-01-01",
    opt_in_date: null,
    opted_in_to_au_backtax: false,
    legal_entity_name: null,
    are_au_backtaxes_paid: false,
    au_backtaxes_paid_date: null,
    show_au_backtax_prompt: false,
  },
  countries: { US: "United States" },
  ip_country_code: "US",
  bank_account_details: {
    show_bank_account: false,
    show_paypal: true,
    is_a_card: false,
    routing_number: null,
    account_number_visual: null,
    card: null,
    card_data_handling_mode: null,
    bank_account: null,
  },
  paypal_address: "seller@example.com",
  stripe_connect: {
    has_connected_stripe: false,
    stripe_connect_account_id: null,
    stripe_disconnect_allowed: false,
    supported_countries_help_text: "",
  },
  fee_info: {
    card_fee_info_text: "",
    paypal_fee_info_text: "",
    connect_account_fee_info_text: "",
  },
  min_dob_year: 2008,
  user: user(userOverrides),
  compliance_info: complianceInfo(complianceOverrides),
  us_business_types: [
    { code: "single_member_llc", name: "LLC (single member)" },
    { code: "multi_member_llc", name: "LLC (multi-member)" },
  ],
  uae_business_types: [],
  india_business_types: [],
  canada_business_types: [],
  states: {
    us: [{ code: "CA", name: "California" }],
    ca: [],
    au: [],
    mx: [],
    ae: [],
    ir: [],
    br: [],
    jp: [],
  },
  saved_card: null,
  formatted_balance_to_forfeit_on_country_change: null,
  formatted_balance_to_forfeit_on_payout_method_change: null,
  paypal_switch_loses_bank_rail: false,
  payouts_paused_internally: false,
  payouts_paused_by: null,
  account_status: {
    show_section: false,
    is_suspended: false,
    suspension_reason: null,
    compliance_actions: [],
    needs_id_upload: false,
    gumroad_status: null,
    social_connections_for_review: null,
    stripe_rejected: false,
    stripe_rejected_balance_status: null,
    stripe_rejected_formatted_balance: null,
    stripe_rejected_payout_date: null,
  },
  payouts_paused_by_user: false,
  payout_threshold_cents: 1000,
  minimum_payout_threshold_cents: 1000,
  payout_country_name: "United States",
  payout_frequency: "weekly",
  payout_frequency_daily_supported: false,
  instant_payout_fee_percent: 3,
  buyer_local_currency_enabled: false,
  disable_buyer_local_currency: false,
  buyer_currency_charging_enabled: false,
  disable_buyer_currency_rounding: false,
  can_manage_beneficial_owners: false,
  legal_guardian: { required: false, unsupported: false, blocking_payouts: false, guardian: null },
});

const renderPage = (userOverrides: Partial<User> = {}, complianceOverrides: Partial<ComplianceInfo> = {}) => {
  mocks.usePage.mockReturnValue({ props: pageProps(userOverrides, complianceOverrides) });
  render(<PaymentsPage />);
};

const save = () => fireEvent.click(screen.getByRole("button", { name: "Update settings" }));

// The inline field hint says "now requires"; the validation banner omits the "now", so an exact
// match keeps the two apart.
const fullSsnError = () =>
  screen.queryByText("Our payments provider requires your full 9-digit Social Security Number.");

const typeSsn = (value: string) => {
  fireEvent.change(screen.getByLabelText("Social Security Number"), { target: { value } });
};

describe("US company representative tax ID", () => {
  const business = {
    is_business: true,
    business_country: "US",
    country: "DZ",
    business_type: "single_member_llc",
    business_name: "Test LLC",
    business_street_address: "1 Main St",
    business_city: "San Francisco",
    business_state: "CA",
    business_zip_code: "94103",
    business_phone: "+14155552671",
    job_title: "Owner",
    phone: "+213551234567",
  };
  it.each(["1234", "12345678", "1234567890", "abcdefghi"])("blocks submission of %s", (value) => {
    renderPage({ individual_tax_id_entered: false }, business);
    fireEvent.change(screen.getByLabelText("Personal tax ID"), { target: { value } });
    save();
    expect(mocks.put).not.toHaveBeenCalled();
    expect(screen.getAllByText("Enter a 9-digit US ITIN or SSN.").length).toBeGreaterThan(0);
  });

  it.each(["000000000", "000-00-0000", "000 00 0000"])(
    "submits nine digits for the foreign representative's formatted ITIN %s",
    (value) => {
      renderPage({ individual_tax_id_entered: false, business_tax_id_entered: true }, business);
      fireEvent.change(screen.getByLabelText("Personal tax ID"), { target: { value } });
      save();
      expect(mocks.put).toHaveBeenCalledWith(
        "/settings_payments",
        expect.objectContaining({
          user: expect.objectContaining({ individual_tax_id: "000000000" }),
        }),
      );
    },
  );

  it.each([true, false])("shows the document CTA only when Stripe offers that alternative: %s", async (offered) => {
    const props = { ...pageProps({ individual_tax_id_entered: false }, business), can_manage_beneficial_owners: true };
    mocks.usePage.mockReturnValue({ props });
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              beneficial_owners: [
                {
                  id: "person_test",
                  first_name: "Test",
                  last_name: "Representative",
                  email: null,
                  phone: null,
                  dob: null,
                  address: { country: "DZ" },
                  relationship: {
                    representative: true,
                    owner: true,
                    director: false,
                    executive: false,
                    title: "Owner",
                    percent_ownership: 100,
                  },
                  id_number_provided: false,
                  ssn_last_4_provided: false,
                  nationality: null,
                  verification_status: "unverified",
                  requirements_currently_due: ["id_number"],
                  requirements_alternatives: offered
                    ? [{ original_fields_due: ["id_number"], alternative_fields_due: ["verification.document"] }]
                    : [],
                },
              ],
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );
    render(<PaymentsPage />);
    await screen.findByText("Stripe needs: Personal tax ID");
    const link = screen.queryByRole("link", { name: "Upload a passport via Stripe instead" });
    if (offered) expect(link?.getAttribute("href")).toBe("/remediation_settings_payments");
    else expect(link).toBeNull();
    vi.unstubAllGlobals();
  });
});

// A stored threshold below the platform minimum changes no payout, so it must not flag the field
// or block saving an unrelated change.
describe("stale payout threshold below the platform minimum", () => {
  const stale = { payout_threshold_cents: 1000, minimum_payout_threshold_cents: 10_000 };
  const saveButton = () => screen.getByRole("button", { name: "Update settings" });
  const thresholdField = () => screen.getByLabelText<HTMLInputElement>("Minimum payout threshold");

  it("does not flag the untouched stored value and still allows saving", () => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale } });
    render(<PaymentsPage />);

    expect(thresholdField().getAttribute("aria-invalid")).toBe("false");
    expect(saveButton().hasAttribute("disabled")).toBe(false);
  });

  it("says the payouts use the minimum while the stored value sits below it", () => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale } });
    render(<PaymentsPage />);

    expect(screen.getByText(/Until you enter a higher amount, your payouts use that minimum\./u)).toBeTruthy();
  });

  it("omits the note once the stored value reaches the minimum", () => {
    renderPage();

    expect(screen.queryByText(/Until you enter a higher amount/u)).toBeNull();
  });

  it("still raises the value when the seller retypes the stale amount", () => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale } });
    render(<PaymentsPage />);

    fireEvent.change(thresholdField(), { target: { value: "10" } });
    save();

    expect(mocks.put).toHaveBeenCalledWith(
      "/settings_payments",
      expect.objectContaining({ payout_threshold_cents: 10_000 }),
    );
  });

  it("raises the untouched stale value to the minimum when saving another change", () => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale, payout_frequency_daily_supported: true } });
    render(<PaymentsPage />);

    fireEvent.change(screen.getByLabelText("Schedule"), { target: { value: "daily" } });
    save();

    expect(mocks.put).toHaveBeenCalledWith(
      "/settings_payments",
      expect.objectContaining({ payout_frequency: "daily", payout_threshold_cents: 10_000 }),
    );
  });

  it("still flags a value the seller types below the minimum and blocks saving", () => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale } });
    render(<PaymentsPage />);

    fireEvent.change(thresholdField(), { target: { value: "50" } });

    expect(thresholdField().getAttribute("aria-invalid")).toBe("true");
    expect(saveButton().hasAttribute("disabled")).toBe(true);
  });

  // These two paths call handleSave past the disabled button.
  it("refuses a value typed below the minimum when the mobile app saves", () => {
    vi.stubGlobal("ReactNativeWebView", { postMessage: vi.fn() });
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), ...stale, is_mobile_app_web_view: true } });
    render(<PaymentsPage />);

    fireEvent.change(thresholdField(), { target: { value: "50" } });
    fireEvent(window, new MessageEvent("message", { data: JSON.stringify({ type: "mobileAppSettingsSave" }) }));

    expect(mocks.put).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });

  it("refuses a value typed below the minimum when the country change is confirmed", () => {
    mocks.usePage.mockReturnValue({
      props: { ...pageProps(), ...stale, countries: { US: "United States", CA: "Canada" } },
    });
    render(<PaymentsPage />);

    fireEvent.change(thresholdField(), { target: { value: "50" } });
    fireEvent.change(screen.getByLabelText("Country"), { target: { value: "CA" } });
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));

    expect(mocks.put).not.toHaveBeenCalled();
  });
});

describe("full-SSN re-entry validation", () => {
  it("blocks saving when Stripe requires the full SSN and only last-4 is on file", () => {
    renderPage({
      need_full_ssn: true,
      has_outstanding_full_ssn_requirement: true,
      individual_tax_id_is_last_four: true,
    });

    save();

    expect(fullSsnError()).toBeTruthy();
    expect(mocks.put).not.toHaveBeenCalled();
  });

  it("blocks saving a fresh value with fewer than 9 digits into a full-SSN requirement", () => {
    renderPage({
      need_full_ssn: true,
      has_outstanding_full_ssn_requirement: true,
      individual_tax_id_is_last_four: true,
    });

    typeSsn("6789");
    save();

    expect(fullSsnError()).toBeTruthy();
    expect(mocks.put).not.toHaveBeenCalled();
  });

  it("saves when a full 9-digit SSN is re-entered", () => {
    renderPage({
      need_full_ssn: true,
      has_outstanding_full_ssn_requirement: true,
      individual_tax_id_is_last_four: true,
    });

    typeSsn("123-45-6789");
    save();

    expect(fullSsnError()).toBeNull();
    expect(mocks.put).toHaveBeenCalledTimes(1);
  });

  it("saves without re-entry when the full SSN is already on file", () => {
    renderPage({
      need_full_ssn: true,
      has_outstanding_full_ssn_requirement: true,
      individual_tax_id_is_last_four: false,
    });

    save();

    expect(fullSsnError()).toBeNull();
    expect(mocks.put).toHaveBeenCalledTimes(1);
  });

  it("saves without re-entry when only last-4 is on file but the full SSN is not required", () => {
    renderPage({
      need_full_ssn: false,
      has_outstanding_full_ssn_requirement: false,
      individual_tax_id_is_last_four: true,
    });

    save();

    expect(fullSsnError()).toBeNull();
    expect(mocks.put).toHaveBeenCalledTimes(1);
  });
  it("saves without re-entry when an old full-SSN request was satisfied another way (no outstanding requirement)", () => {
    renderPage({
      need_full_ssn: true,
      has_outstanding_full_ssn_requirement: false,
      individual_tax_id_is_last_four: true,
    });

    save();

    expect(fullSsnError()).toBeNull();
    expect(mocks.put).toHaveBeenCalledTimes(1);
  });
  it("blocks saving for a US business whose individual country is not US (requirement follows business_country)", () => {
    renderPage(
      {
        need_full_ssn: true,
        has_outstanding_full_ssn_requirement: true,
        individual_tax_id_is_last_four: true,
        business_tax_id_entered: true,
      },
      {
        is_business: true,
        country: "CA",
        // Complete business fields so no later validation overwrites the SSN error message.
        business_type: "llc",
        business_name: "Test LLC",
        business_street_address: "123 Main St",
        business_city: "San Francisco",
        business_state: "CA",
        business_country: "US",
        business_zip_code: "94103",
        business_phone: "+14155552671",
      },
    );

    save();

    expect(fullSsnError()).toBeTruthy();
    expect(mocks.put).not.toHaveBeenCalled();
  });
});

describe("buyer local currency description", () => {
  const renderWithCurrencyProps = (overrides: Record<string, unknown>) => {
    mocks.usePage.mockReturnValue({ props: { ...pageProps(), buyer_local_currency_enabled: true, ...overrides } });
    render(<PaymentsPage />);
  };

  it("describes the checkout currency choice only when buyer-currency charging is enabled", () => {
    renderWithCurrencyProps({ buyer_currency_charging_enabled: true });

    expect(
      screen.getByText(/When this is on, buyers can also choose the currency they pay in at checkout/u),
    ).toBeTruthy();
    expect(screen.queryByText(/Checkout still uses USD/u)).toBeNull();
  });

  it("keeps the USD checkout description while charging is not enabled for the seller", () => {
    renderWithCurrencyProps({ buyer_currency_charging_enabled: false });

    expect(screen.getByText(/Checkout still uses USD/u)).toBeTruthy();
    expect(screen.queryByText(/choose the currency they pay in/u)).toBeNull();
  });
});

describe("business type validation", () => {
  const business = {
    is_business: true,
    business_type: "llc",
    business_country: "US",
    business_name: "Example LLC",
    business_street_address: "123 Main St",
    business_city: "San Francisco",
    business_state: "CA",
    business_zip_code: "94103",
    business_phone: "+14155552671",
    job_title: "Owner",
  };

  it("blocks a legacy US LLC until the seller selects its member count", () => {
    renderPage({ business_tax_id_entered: true }, business);
    const select = screen.getByLabelText<HTMLSelectElement>("Type");
    expect(select.value).toBe("");
    save();
    expect(select.getAttribute("aria-invalid")).toBe("true");
    expect(screen.getByText("Please complete the required fields below: Type.")).toBeTruthy();
    expect(mocks.put).not.toHaveBeenCalled();

    fireEvent.change(select, { target: { value: "multi_member_llc" } });
    save();
    expect(mocks.put).toHaveBeenCalledTimes(1);
    expect(mocks.put.mock.calls[0]?.[1]).toMatchObject({ user: { business_type: "multi_member_llc" } });
  });

  it("still accepts a generic LLC where the active country list offers it", () => {
    renderPage({ business_tax_id_entered: true }, { ...business, business_country: "GB" });
    save();
    expect(mocks.put).toHaveBeenCalledTimes(1);
  });
});

describe("server error naming a field", () => {
  const message =
    "Our payment partner couldn't find a bank for the bank code QNBAEGCX027. Use the 8-character SWIFT/BIC code instead: QNBAEGCX rather than QNBAEGCX027.";

  const renderWithServerError = (errors: Record<string, unknown>) => {
    mocks.usePage.mockReturnValue({
      props: {
        ...pageProps({ country_code: "EG", country_supports_iban: true, payout_currency: "egp" }, { country: "EG" }),
        countries: { EG: "Egypt" },
        bank_account_details: {
          show_bank_account: true,
          show_paypal: false,
          is_a_card: false,
          routing_number: null,
          account_number_visual: null,
          card: null,
          card_data_handling_mode: null,
          bank_account: null,
        },
        errors,
      },
    });
    render(<PaymentsPage />);
  };

  it("shows the banner and flags the named bank-code input", () => {
    renderWithServerError({ base: [message], field: "bank_code" });

    expect(screen.getByText(message)).toBeTruthy();
    expect(screen.getByLabelText("SWIFT / BIC Code").getAttribute("aria-invalid")).toBe("true");
  });

  it("shows only the banner when the server names no field", () => {
    renderWithServerError({ base: [message] });

    expect(screen.getByText(message)).toBeTruthy();
    expect(screen.getByLabelText("SWIFT / BIC Code").getAttribute("aria-invalid")).toBe("false");
  });
});

describe("switching to PayPal where the bank rail cannot be re-created", () => {
  // An India seller with a live bank account: the save deletes it and Stripe refuses a new IND
  // account, so the confirmation must fire even with nothing forfeitable.
  const renderIndiaSeller = (paypal_switch_loses_bank_rail: boolean, balance: string | null = null) => {
    mocks.usePage.mockReturnValue({
      props: {
        ...pageProps({ country_code: "IN", payout_currency: "inr" }, { country: "IN" }),
        countries: { IN: "India" },
        paypal_switch_loses_bank_rail,
        formatted_balance_to_forfeit_on_payout_method_change: balance,
        paypal_address: null,
        bank_account_details: {
          show_bank_account: true,
          show_paypal: true,
          is_a_card: false,
          routing_number: "HDFC0004051",
          account_number_visual: "******6789",
          card: null,
          card_data_handling_mode: null,
          bank_account: null,
        },
      },
    });
    render(<PaymentsPage />);
    fireEvent.click(screen.getByRole("radio", { name: "PayPal" }));
    fireEvent.change(screen.getByLabelText("PayPal Email"), { target: { value: "paypal@example.com" } });
  };

  it("opens the typed confirmation instead of saving, then saves with the confirmation flag", () => {
    renderIndiaSeller(true);
    save();

    expect(mocks.put).not.toHaveBeenCalled();
    expect(screen.getByText(/you will not be able to switch back/u)).toBeTruthy();
    expect(within(screen.getByRole("dialog")).getByText("******6789")).toBeTruthy();
    expect(screen.getByRole("dialog").textContent).toContain("PayPal, you will not be able to switch back");
    const confirm = screen.getByRole("button", { name: "Confirm" });
    expect(confirm.hasAttribute("disabled")).toBe(true);

    fireEvent.change(screen.getByLabelText('Type "I understand" to confirm'), { target: { value: "I understand" } });
    expect(confirm.hasAttribute("disabled")).toBe(false);
    fireEvent.click(confirm);

    expect(mocks.put).toHaveBeenCalledWith(
      "/settings_payments",
      expect.objectContaining({ payment_address: "paypal@example.com", confirm_bank_rail_loss: true }),
    );
  });

  it("shows both losses and requires typed confirmation when a balance is also forfeited", () => {
    renderIndiaSeller(true, "$123.45");
    save();

    expect(screen.getByText(/forfeit your existing balance of/u)).toBeTruthy();
    expect(screen.getByText("$123.45")).toBeTruthy();
    expect(screen.getByText(/you will not be able to switch back/u)).toBeTruthy();
    expect(within(screen.getByRole("dialog")).getByText("******6789")).toBeTruthy();
    expect(screen.getByRole("dialog").textContent).toContain("PayPal, you will not be able to switch back");
    const confirm = screen.getByRole("button", { name: "Confirm" });
    fireEvent.change(screen.getByLabelText('Type "I understand" to confirm'), { target: { value: "understand" } });
    expect(confirm.hasAttribute("disabled")).toBe(true);
    expect(mocks.put).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('Type "I understand" to confirm'), { target: { value: "I understand" } });
    fireEvent.click(confirm);
    expect(mocks.put).toHaveBeenCalledWith(
      "/settings_payments",
      expect.objectContaining({ payment_address: "paypal@example.com", confirm_bank_rail_loss: true }),
    );
  });

  it("names the removed account when only the balance is forfeited", () => {
    renderIndiaSeller(false, "$123.45");
    save();

    const dialog = screen.getByRole("dialog");
    expect(within(dialog).getByText("******6789")).toBeTruthy();
    expect(dialog.textContent).toContain("Your bank account ******6789 will be removed.");
    expect(within(dialog).getByText("$123.45")).toBeTruthy();
    expect(within(dialog).queryByText(/you will not be able to switch back/u)).toBeNull();
    expect(mocks.put).not.toHaveBeenCalled();
  });

  it("saves straight away where the rail can be re-created", () => {
    renderIndiaSeller(false);
    save();

    expect(screen.queryByText(/you will not be able to switch back/u)).toBeNull();
    expect(mocks.put).toHaveBeenCalledTimes(1);
    expect(mocks.put).toHaveBeenCalledWith(
      "/settings_payments",
      expect.objectContaining({ payment_address: "paypal@example.com" }),
    );
    expect(JSON.stringify(mocks.put.mock.calls[0])).not.toContain("confirm_bank_rail_loss");
  });
});
