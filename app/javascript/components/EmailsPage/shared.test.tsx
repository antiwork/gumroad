// @vitest-environment happy-dom
//
// "Resend to non-openers" is offered for Everyone posts too: their recipients are resolved from
// the post's own sent set, and the confirm control says opens are approximate because Apple Mail
// prefetch inflates them.
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { getNonOpenerCount, type SavedInstallment } from "$app/data/installments";

import { canResendToNonOpeners, ResendToNonOpenersButton } from "$app/components/EmailsPage/shared";

vi.mock("$app/data/installments", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/installments")>();
  return { ...actual, getNonOpenerCount: vi.fn(), resendToNonOpeners: vi.fn() };
});

vi.mock("@inertiajs/react", () => ({
  router: { reload: vi.fn() },
  useForm: () => ({ processing: false, delete: vi.fn() }),
}));

const post = (installment_type: string): SavedInstallment => ({
  external_id: "email-1",
  display_type: "published",
  name: "August update",
  message: "Hello",
  published_at: "2026-08-01T00:00:00Z",
  updated_at: "2026-08-01T00:00:00Z",
  stream_only: false,
  streamable: false,
  send_emails: true,
  shown_on_profile: false,
  installment_type,
  paid_more_than_cents: null,
  paid_less_than_cents: null,
  allow_comments: true,
  full_url: "https://seller.gumroad.com/p/august-update",
  has_been_blasted: true,
  files: [],
  shown_in_profile_sections: [],
});

afterEach(cleanup);

describe("canResendToNonOpeners", () => {
  it("offers the resend on an Everyone post", () => {
    expect(canResendToNonOpeners(post("audience"))).toBe(true);
  });

  it("does not offer it on a follower post, whose recipients the resend cannot resolve", () => {
    expect(canResendToNonOpeners(post("follower"))).toBe(false);
  });
});

describe("ResendToNonOpenersButton", () => {
  it("says on the control that opens are approximate", async () => {
    vi.mocked(getNonOpenerCount).mockResolvedValue({ count: 3, recently_resent: false, audience_filtered_out: false });

    render(<ResendToNonOpenersButton installment={post("audience")} />);
    fireEvent.click(screen.getByRole("button", { name: "Resend to non-openers" }));

    expect(await screen.findByText(/Opens are approximate/u)).toBeTruthy();
  });
});
