// @vitest-environment happy-dom
import { router } from "@inertiajs/react";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { set } from "lodash-es";
import * as React from "react";
import { afterEach, beforeAll, expect, it, vi } from "vitest";

import InvoicePage from "$app/pages/Purchases/Invoices/New";

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  visit: vi.fn<typeof router.visit>(),
  post: vi.fn(),
  error: vi.fn(),
  submittedData: vi.fn(),
}));
vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  router: { visit: mocks.visit },
  useForm: <T extends Record<string, unknown>>(initial: T) => {
    const [data, setDataState] = React.useState(initial);
    const [defaults, setDefaults] = React.useState(initial);
    const transform = React.useRef((data: T) => data);
    return {
      data,
      isDirty: JSON.stringify(data) !== JSON.stringify(defaults),
      processing: false,
      errors: {},
      setData: (key: string, value: unknown) => setDataState((previous) => set(structuredClone(previous), key, value)),
      setError: mocks.error,
      transform: (callback: (data: T) => T) => {
        transform.current = callback;
      },
      post: (...args: Parameters<typeof mocks.post>) => {
        mocks.post(...args);
        mocks.submittedData(transform.current(data));
        setDefaults(data);
      },
    };
  },
}));
vi.mock("$app/components/PoweredByFooter", () => ({ PoweredByFooter: () => null }));

beforeAll(() => {
  Object.assign(globalThis, { Routes: { purchase_invoice_path: (id: string) => `/purchases/${id}/invoice` } });
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const formData = (purchase_id: string) => ({
  purchase_id,
  email: "buyer@example.com",
  address_fields: {
    full_name: "Buyer",
    street_address: "1 Main St",
    city: "San Francisco",
    state: "CA",
    zip_code: "94103",
    country_code: "US",
  },
  business_name: "",
  vat_id: "",
  additional_notes: "",
});
const pageProps = (purchase_id: string) => ({
  form_data: formData(purchase_id),
  form_metadata: {
    heading: "Generate invoice",
    display_vat_id: false,
    vat_id_label: "VAT",
    business_id_country_codes: [],
    business_id_labels: {},
    supplier_info: { heading: "Supplier", attributes: [] },
    seller_info: { heading: "Seller", attributes: [] },
    order_info: {
      heading: "Order",
      invoice_date_attribute: { label: "Invoice date", value: "Jun 25, 2026" },
      form_attributes: [],
    },
    countries: { US: "United States", BW: "Botswana", GM: "Gambia", CA: "Canada" },
  },
  payment_id: purchase_id,
  payments: [
    { id: "july", label: "Jul 25, 2026 · $20", url: "/purchases/july/invoice/new?email=buyer@example.com" },
    { id: "june", label: "Jun 25, 2026 · $10", url: "/purchases/june/invoice/new?email=buyer@example.com" },
  ],
});

it.each(["BW", "GM"])("accepts a complete %s address without state or ZIP", (country) => {
  const props = pageProps("july");
  props.form_data.address_fields = {
    ...props.form_data.address_fields,
    country_code: country,
    state: "",
    zip_code: "",
  };
  mocks.usePage.mockReturnValue({ props });
  render(<InvoicePage />);
  expect(screen.queryByLabelText("ZIP code")).toBeNull();
  expect(screen.queryByLabelText("State")).toBeNull();
  expect(screen.queryByText("94107")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.error).not.toHaveBeenCalled();
  expect(mocks.submittedData).toHaveBeenCalledWith(
    expect.objectContaining({
      address_fields: expect.objectContaining({ country_code: country, zip_code: "", state: "" }),
    }),
  );
});

it("omits a stale hidden ZIP and restores its validation when switching countries", () => {
  mocks.usePage.mockReturnValue({ props: pageProps("july") });
  render(<InvoicePage />);
  fireEvent.change(screen.getByLabelText("Country"), { target: { value: "BW" } });
  expect(screen.queryByLabelText("ZIP code")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.submittedData).toHaveBeenLastCalledWith(
    expect.objectContaining({ address_fields: expect.objectContaining({ zip_code: "", state: "" }) }),
  );
  fireEvent.change(screen.getByLabelText("Country"), { target: { value: "US" } });
  expect(screen.getByLabelText("ZIP code")).toHaveProperty("value", "94103");
  expect(screen.getByLabelText("State")).toHaveProperty("value", "CA");
  fireEvent.change(screen.getByLabelText("ZIP code"), { target: { value: "" } });
  mocks.post.mockClear();
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.error).toHaveBeenCalledWith("address_fields.zip_code", expect.any(String));
  expect(mocks.post).not.toHaveBeenCalled();
});

it.each(["US", "CA"])("still requires ZIP for a %s address", (country) => {
  const props = pageProps("july");
  props.form_data.address_fields.country_code = country;
  props.form_data.address_fields.zip_code = "";
  mocks.usePage.mockReturnValue({ props });
  render(<InvoicePage />);
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.error).toHaveBeenCalledWith("address_fields.zip_code", expect.any(String));
  expect(mocks.post).not.toHaveBeenCalled();
});

it("keeps entered invoice details when selecting another payment and submits for that payment", () => {
  let props = pageProps("july");
  mocks.usePage.mockImplementation(() => ({ props }));
  const { rerender } = render(<InvoicePage />);

  fireEvent.change(screen.getByLabelText("Business name (optional)"), { target: { value: "My business" } });
  fireEvent.change(screen.getByLabelText("Payment"), { target: { value: "june" } });

  expect(mocks.visit.mock.lastCall?.[0]).toBe("/purchases/june/invoice/new?email=buyer@example.com");
  expect(mocks.visit.mock.lastCall?.[1]?.preserveState).toBe(true);
  expect(typeof mocks.visit.mock.lastCall?.[1]?.onSuccess).toBe("function");
  props = pageProps("june");
  rerender(<InvoicePage />);
  const onSuccess = mocks.visit.mock.lastCall?.[1]?.onSuccess;
  act(() => {
    onSuccess?.({
      component: "Purchases/Invoices/New",
      props: { ...props, errors: {} },
      url: "/purchases/june/invoice/new",
      version: null,
      clearHistory: false,
      encryptHistory: false,
      flash: {},
      rememberedState: {},
    });
  });
  expect(screen.getByDisplayValue("My business")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.post).toHaveBeenCalledWith("/purchases/june/invoice", expect.anything());
});

it("retains invoice details when the form is clean after a successful download", () => {
  mocks.usePage.mockReturnValue({ props: pageProps("july") });
  render(<InvoicePage />);

  fireEvent.change(screen.getByLabelText("Business name (optional)"), { target: { value: "My business" } });
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.post).toHaveBeenCalledWith("/purchases/july/invoice", expect.anything());

  fireEvent.change(screen.getByLabelText("Payment"), { target: { value: "june" } });
  expect(mocks.visit.mock.lastCall?.[1]?.preserveState).toBe(true);
  act(() => {
    mocks.visit.mock.lastCall?.[1]?.onSuccess?.({
      component: "Purchases/Invoices/New",
      props: { ...pageProps("june"), errors: {} },
      url: "/purchases/june/invoice/new",
      version: null,
      clearHistory: false,
      encryptHistory: false,
      flash: {},
      rememberedState: {},
    });
  });
  expect(screen.getByDisplayValue("My business")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Download" }));
  expect(mocks.post).toHaveBeenLastCalledWith("/purchases/june/invoice", expect.anything());
});
