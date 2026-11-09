// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Show from "$app/pages/Purchases/RefundRequest/Show";

const mocks = vi.hoisted(() => ({ usePage: vi.fn(), post: vi.fn() }));

vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  useForm: <T,>(initial: T) => {
    const [data, setDataState] = React.useState(initial);
    return {
      data,
      processing: false,
      setData: (key: keyof T, value: T[keyof T]) => setDataState((prev) => ({ ...prev, [key]: value })),
      post: (url: string) => {
        mocks.post(url, data);
      },
    };
  },
}));

const baseProps = {
  purchase_route_id: "signed-token",
  product_name: "Watercolor brush pack",
  creator_name: "Jane",
  formatted_price: "$29",
  respond_by: "Wednesday, November 11",
  max_message_length: 2000,
  reasons: [
    { value: "not_received", label: "I never received the product" },
    { value: "other", label: "Something else" },
  ],
  refund_request: null,
  ineligibility: null,
  refund_window_ended_on: null,
};

const renderWith = (props: Record<string, unknown>) => {
  mocks.usePage.mockReturnValue({ props: { ...baseProps, ...props } });
  return render(<Show />);
};

describe("RefundRequest Show", () => {
  beforeEach(() => {
    Object.assign(globalThis, {
      Routes: { purchase_refund_request_path: (id: string) => `/purchases/${id}/refund_request` },
    });
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("posts the chosen reason and message to the token's refund request path", () => {
    renderWith({});

    fireEvent.click(screen.getByRole("radio", { name: "Something else" }));
    fireEvent.change(screen.getByRole("textbox", { name: "Anything else Jane should know? (optional)" }), {
      target: { value: "Files are corrupted." },
    });
    fireEvent.click(screen.getByRole("button", { name: "Send refund request" }));

    expect(mocks.post).toHaveBeenCalledWith("/purchases/signed-token/refund_request", {
      reason: "other",
      message: "Files are corrupted.",
    });
  });

  it("tells the buyer who decides and by when before they send", () => {
    renderWith({});

    expect(
      screen.getByText(
        "Sending this request doesn't refund you yet. Jane decides first. If you aren't refunded by Wednesday, November 11, Gumroad support will review your request.",
      ),
    ).toBeTruthy();
  });

  it("shows the existing request's status instead of the form", () => {
    renderWith({
      refund_request: { state: "requested", email: "buyer@example.com", reason_label: "Something else" },
    });

    expect(screen.getByRole("heading", { name: "Refund requested" })).toBeTruthy();
    expect(screen.getByText("We sent your request to Jane.")).toBeTruthy();
    expect(screen.getByText(/If you aren't refunded by Wednesday, November 11/u)).toBeTruthy();
    expect(screen.getByText("Reason: Something else")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Send refund request" })).toBeNull();
  });

  it("tells the buyer support has an escalated request", () => {
    renderWith({
      refund_request: { state: "escalated", email: "buyer@example.com", reason_label: "Something else" },
    });

    expect(screen.getByRole("heading", { name: "Gumroad support is reviewing your request" })).toBeTruthy();
    expect(screen.getByText("We'll email you at buyer@example.com when we have an answer.")).toBeTruthy();
  });

  it("explains why a refunded purchase is not eligible", () => {
    renderWith({ ineligibility: "refunded" });

    expect(screen.getByRole("heading", { name: "Refund not available" })).toBeTruthy();
    expect(screen.getByText("This purchase has already been refunded.")).toBeTruthy();
    expect(screen.queryByRole("radio")).toBeNull();
  });

  it("gives the date the refund window ended", () => {
    renderWith({ ineligibility: "outside_window", refund_window_ended_on: "Friday, October 9" });

    expect(
      screen.getByText(
        "The refund window for this purchase ended on Friday, October 9. To ask Jane anyway, reply to your receipt email.",
      ),
    ).toBeTruthy();
  });

  it("explains a request closed by a refund that didn't go through", () => {
    renderWith({
      refund_request: { state: "expired", email: "buyer@example.com", reason_label: "Something else" },
      ineligibility: "previous_request_closed",
    });

    expect(screen.getByRole("heading", { name: "Refund request closed" })).toBeTruthy();
    expect(screen.getByText("The refund for this purchase didn't go through, so this request is closed.")).toBeTruthy();
  });
});
