// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import Payout, { type Payout as PayoutProps } from "$app/components/Admin/Payouts/Payout";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("@inertiajs/react", () => ({
  Link: ({ children, href, ...props }: { children: React.ReactNode; href: string }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

vi.mock("$app/components/Admin/DateTimeWithRelativeTooltip", () => ({ default: () => null }));
vi.mock("$app/components/Admin/ActionButton", () => ({ AdminActionButton: () => null }));

beforeAll(() => {
  vi.stubEnv("TZ", "America/Los_Angeles");
});

afterAll(() => {
  vi.unstubAllEnvs();
});

afterEach(cleanup);

const payout: PayoutProps = {
  external_id: "payout-external-id",
  displayed_amount: "$100",
  user: { external_id: "user-external-id", name: "Seller" },
  processor: "paypal",
  payout_period_end_date: "2026-08-04",
  processor_fee_cents: 0,
  state: "completed",
  is_stripe_processor: false,
  is_paypal_processor: true,
  stripe_transfer_id: null,
  stripe_transfer_url: null,
  stripe_connect_account_id: null,
  stripe_connected_account_url: null,
  failed: false,
  humanized_failure_reason: null,
  bank_account: null,
  payment_address: "seller@example.com",
  txn_id: null,
  correlation_id: null,
  was_created_in_split_mode: false,
  split_payments_info: null,
  cancelled: false,
  returned: false,
  processing: false,
  created_at: "2026-08-05T00:00:00Z",
  unclaimed: false,
  non_terminal_state: false,
};

describe("Payout", () => {
  it("renders the payout period as its calendar date west of UTC", () => {
    const { container } = render(<Payout payout={payout} />);
    const label = Array.from(container.querySelectorAll("dt")).find(
      (element) => element.textContent === "Payout period end date",
    );

    expect(label?.nextElementSibling?.textContent).toBe("August 4, 2026");
  });
});
