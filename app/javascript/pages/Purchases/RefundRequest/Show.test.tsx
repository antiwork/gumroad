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
  formatted_price: "$29",
  escalation_business_days: 2,
  max_message_length: 2000,
  reasons: [
    { value: "not_received", label: "I never received the product" },
    { value: "other", label: "Something else" },
  ],
  refund_request: null,
  ineligibility: null,
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
    fireEvent.change(screen.getByRole("textbox", { name: "Anything else the creator should know? (optional)" }), {
      target: { value: "Files are corrupted." },
    });
    fireEvent.click(screen.getByRole("button", { name: "Send refund request" }));

    expect(mocks.post).toHaveBeenCalledWith("/purchases/signed-token/refund_request", {
      reason: "other",
      message: "Files are corrupted.",
    });
  });

  it("shows the existing request's status instead of the form", () => {
    renderWith({
      refund_request: { state: "requested", email: "buyer@example.com", reason_label: "Something else" },
    });

    expect(screen.getByText("Your refund request has been sent to the creator.")).toBeTruthy();
    expect(screen.getByText("Reason: Something else")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Send refund request" })).toBeNull();
  });

  it("tells the buyer support has an escalated request", () => {
    renderWith({
      refund_request: { state: "escalated", email: "buyer@example.com", reason_label: "Something else" },
    });

    expect(screen.getByText("Gumroad support is reviewing your refund request.")).toBeTruthy();
    expect(screen.getByText("You'll hear from us at buyer@example.com.")).toBeTruthy();
  });

  it("explains why a refunded purchase is not eligible", () => {
    renderWith({ ineligibility: "refunded" });

    expect(screen.getByText("It has already been refunded.")).toBeTruthy();
    expect(screen.queryByRole("radio")).toBeNull();
  });
});
