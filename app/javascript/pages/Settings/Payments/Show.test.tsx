// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
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
      setData: (key: keyof T, value: T[keyof T]) => setDataState((prev) => ({ ...prev, [key]: value })),
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
  payouts_paused_internally: false,
  payouts_paused_by: null,
  account_status: {
    show_section: false,
    is_suspended: false,
    suspension_reason: null,
    compliance_actions: [],
    needs_id_upload: false,
    gumroad_status: null,
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
