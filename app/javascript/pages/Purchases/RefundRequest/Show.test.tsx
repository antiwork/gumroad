// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import RefundRequestPage from "$app/pages/Purchases/RefundRequest/Show";

const mocks = vi.hoisted(() => ({ usePage: vi.fn() }));
vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  useForm: (initial: Record<string, string>) => {
    const [data, setData] = React.useState(initial);
    return {
      data,
      processing: false,
      errors: {},
      setData: (key: string, value: string) => setData((previous) => ({ ...previous, [key]: value })),
      post: vi.fn(),
    };
  },
}));

afterEach(cleanup);

it("shows how many characters of the message limit are used", () => {
  mocks.usePage.mockReturnValue({
    props: {
      purchase_route_id: "abc",
      product_name: "Product",
      seller_name: "Seller",
      formatted_price: "$10",
      respond_by: "Nov 20",
      max_message_length: 500,
      reasons: [{ value: "other", label: "Other" }],
      refund_request: null,
      ineligibility: null,
      refund_window_ended_on: null,
    },
  });
  render(<RefundRequestPage />);

  expect(screen.getByText("0 of 500 characters used")).toBeTruthy();
  fireEvent.change(screen.getByRole("textbox"), { target: { value: "hello" } });
  expect(screen.getByText("5 of 500 characters used")).toBeTruthy();
});
