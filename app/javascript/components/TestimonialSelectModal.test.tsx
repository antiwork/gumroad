// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { getReviews, type Review } from "$app/data/product_reviews";

import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";

vi.mock("$app/data/product_reviews", () => ({ getReviews: vi.fn() }));
vi.mock("@boxicons/react", () => ({ Check: () => null }));
vi.mock("$app/components/Modal", () => ({
  Modal: ({ open, children, footer }: { open: boolean; children: React.ReactNode; footer: React.ReactNode }) =>
    open ? (
      <div>
        {children}
        {footer}
      </div>
    ) : null,
}));
vi.mock("$app/components/Review", () => ({ Review: ({ review }: { review: Review }) => <p>{review.message}</p> }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const response = (message: string): Awaited<ReturnType<typeof getReviews>> => ({
  reviews: [
    {
      id: message,
      rating: 5,
      message,
      rater: { name: "Reader", avatar_url: "" },
      purchase_id: null,
      created_at: "2026-10-22",
      is_new: false,
      response: null,
      video: null,
    },
  ],
  pagination: { page: 1, pages: 1 },
});

it("does not append a previous opening's response after reopening", async () => {
  let finishOld!: (value: Awaited<ReturnType<typeof getReviews>>) => void;
  vi.mocked(getReviews).mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finishOld = resolve;
      }),
  );
  const props = { onClose: vi.fn(), onInsert: vi.fn(), productId: "product-1" };
  const { rerender } = render(<TestimonialSelectModal {...props} isOpen />);
  rerender(<TestimonialSelectModal {...props} isOpen={false} />);
  vi.mocked(getReviews).mockResolvedValueOnce(response("Current review"));
  await act(async () => {
    rerender(<TestimonialSelectModal {...props} isOpen />);
    await Promise.resolve();
  });
  expect(screen.queryByText("Current review")).not.toBeNull();

  await act(async () => {
    finishOld(response("Obsolete review"));
    await Promise.resolve();
  });

  expect(screen.queryByText("Obsolete review")).toBeNull();
  expect(screen.getAllByRole("checkbox", { name: "Select review" })).toHaveLength(1);
});

it("reloads and clears selections when the product changes while open", async () => {
  vi.mocked(getReviews).mockResolvedValueOnce(response("First product review"));
  const props = { onClose: vi.fn(), onInsert: vi.fn() };
  let rerender!: ReturnType<typeof render>["rerender"];
  await act(async () => {
    ({ rerender } = render(<TestimonialSelectModal {...props} productId="first" isOpen />));
    await Promise.resolve();
  });
  expect(screen.queryByText("First product review")).not.toBeNull();
  fireEvent.click(screen.getByRole("checkbox", { name: "Select review" }));
  expect(screen.getByRole<HTMLInputElement>("checkbox", { name: "Select review" }).checked).toBe(true);
  vi.mocked(getReviews).mockResolvedValueOnce(response("Second product review"));
  await act(async () => {
    rerender(<TestimonialSelectModal {...props} productId="second" isOpen />);
    await Promise.resolve();
  });
  expect(screen.queryByText("First product review")).toBeNull();
  expect(screen.queryByText("Second product review")).not.toBeNull();
  expect(screen.getByRole<HTMLInputElement>("checkbox", { name: "Select review" }).checked).toBe(false);
  expect(screen.getByRole<HTMLButtonElement>("button", { name: "Insert" }).disabled).toBe(true);
});
