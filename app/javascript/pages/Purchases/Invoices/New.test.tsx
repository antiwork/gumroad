// @vitest-environment happy-dom
import { router } from "@inertiajs/react";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, expect, it, vi } from "vitest";

import InvoicePage from "$app/pages/Purchases/Invoices/New";

const mocks = vi.hoisted(() => ({ usePage: vi.fn(), visit: vi.fn<typeof router.visit>(), post: vi.fn() }));
vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  router: { visit: mocks.visit },
  useForm: <T extends Record<string, unknown>>(initial: T) => {
    const [data, setDataState] = React.useState(initial);
    const [defaults, setDefaults] = React.useState(initial);
    return {
      data,
      isDirty: JSON.stringify(data) !== JSON.stringify(defaults),
      processing: false,
      errors: {},
      setData: (key: keyof T, value: T[keyof T]) => setDataState((previous) => ({ ...previous, [key]: value })),
      setError: vi.fn(),
      transform: vi.fn(),
      post: (...args: Parameters<typeof mocks.post>) => {
        mocks.post(...args);
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
    countries: { US: "United States" },
  },
  payment_id: purchase_id,
  payments: [
    { id: "july", label: "Jul 25, 2026 · $20", url: "/purchases/july/invoice/new?email=buyer@example.com" },
    { id: "june", label: "Jun 25, 2026 · $10", url: "/purchases/june/invoice/new?email=buyer@example.com" },
  ],
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
