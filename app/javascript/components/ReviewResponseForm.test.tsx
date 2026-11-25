// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { deleteReviewResponse, updateReviewResponse } from "$app/data/customers";
import { ResponseError } from "$app/utils/request";

import { ReviewResponseForm } from "$app/components/ReviewResponseForm";

vi.mock("$app/data/customers", () => ({ updateReviewResponse: vi.fn(), deleteReviewResponse: vi.fn() }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { product_review_response: { update: true } } }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeEach(() => {
  vi.resetAllMocks();
  vi.mocked(updateReviewResponse).mockResolvedValue(undefined);
  vi.mocked(deleteReviewResponse).mockResolvedValue(undefined);
});
afterEach(cleanup);

const form = (message: string | undefined) => (
  <ReviewResponseForm message={message} purchaseId="purchase-id" onChange={vi.fn()} />
);
const replyBox = () => screen.getByRole<HTMLTextAreaElement>("textbox");

describe("ReviewResponseForm draft state", () => {
  it.each([
    { action: "Add response", message: undefined, expected: "" },
    { action: "Edit", message: "Saved reply", expected: "Saved reply" },
  ])("discards a cancelled draft when $action is reopened", ({ action, message, expected }) => {
    render(form(message));
    fireEvent.click(screen.getByRole("button", { name: action }));
    fireEvent.change(replyBox(), { target: { value: "Cancelled draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.click(screen.getByRole("button", { name: action }));

    expect(replyBox().value).toBe(expected);
    expect(updateReviewResponse).not.toHaveBeenCalled();
  });

  it("starts a blank response after the saved reply is deleted", async () => {
    const StatefulForm = () => {
      const [message, setMessage] = React.useState<string | undefined>("Deleted reply");
      return (
        <ReviewResponseForm
          message={message}
          purchaseId="purchase-id"
          onChange={(response) => setMessage(response?.message)}
        />
      );
    };
    render(<StatefulForm />);
    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    fireEvent.click(
      within(screen.getByRole("dialog", { name: "Delete this response?" })).getByRole("button", { name: "Delete" }),
    );
    fireEvent.click(await screen.findByRole("button", { name: "Add response" }));

    expect(deleteReviewResponse).toHaveBeenCalledWith("purchase-id");
    expect(replyBox().value).toBe("");
  });

  it("uses the latest saved message when opening the editor", () => {
    const { rerender } = render(form("Old reply"));
    rerender(form("Latest reply"));
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));

    expect(replyBox().value).toBe("Latest reply");
  });

  it("keeps the draft available after a failed save", async () => {
    vi.mocked(updateReviewResponse).mockRejectedValueOnce(new ResponseError("Please try again."));
    render(form("Saved reply"));
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
    fireEvent.change(replyBox(), { target: { value: "Retry this draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    await waitFor(() => expect(updateReviewResponse).toHaveBeenCalledWith("purchase-id", "Retry this draft"));
    await waitFor(() => expect(replyBox().disabled).toBe(false));
    expect(replyBox().value).toBe("Retry this draft");
  });
});
