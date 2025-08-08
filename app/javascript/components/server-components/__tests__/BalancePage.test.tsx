import { render, screen } from "@testing-library/react";
import * as React from "react";

import BalancePage from "../BalancePage";

// Mock the modules that BalancePage depends on
jest.mock("$app/utils/serverComponentUtil", () => ({
  register: ({ component }: { component: React.ComponentType }) => component,
}));

jest.mock("ts-safe-cast", () => ({
  cast: (data: unknown) => data,
  createCast: () => (data: unknown) => data,
}));

// Mock all the imported components
jest.mock("$app/components/Button", () => ({
  Button: ({ children, ...props }: React.ComponentProps<"button">) => <button {...props}>{children}</button>,
  NavigationButton: ({ children, ...props }: React.ComponentProps<"a">) => <a {...props}>{children}</a>,
}));

jest.mock("$app/components/Icons", () => ({
  Icon: ({ name }: { name: string }) => <span data-testid={`icon-${name}`} />,
}));

jest.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({
    policies: {
      settings_payments_user: { show: true },
      balance: { export: true },
    },
  }),
}));

jest.mock("$app/components/Modal", () => ({
  Modal: ({ children, open, title }: { children: React.ReactNode; open: boolean; title: string }) =>
    open ? (
      <div role="dialog" aria-label={title}>
        {children}
      </div>
    ) : null,
}));

jest.mock("$app/components/server-components/Alert", () => ({
  showAlert: jest.fn(),
}));

jest.mock("$app/components/server-components/BalancePage/ExportPayoutsPopover", () => ({
  ExportPayoutsPopover: () => <div data-testid="export-payouts-popover" />,
}));

jest.mock("$app/components/UserAgent", () => ({
  useUserAgentInfo: () => ({ locale: "en-US" }),
}));

jest.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children: React.ReactNode }) => children,
}));

// Mock data functions
jest.mock("$app/data/balance", () => ({
  exportPayouts: jest.fn(),
}));

jest.mock("$app/data/payout", () => ({
  createInstantPayout: jest.fn(),
}));

// Mock utility functions
jest.mock("$app/utils/currency", () => ({
  formatPriceCentsWithCurrencySymbol: (_currency: string, cents: number) => `$${(cents / 100).toFixed(2)}`,
  formatPriceCentsWithoutCurrencySymbol: (_currency: string, cents: number) => `${(cents / 100).toFixed(2)}`,
}));

jest.mock("$app/utils/promise", () => ({
  asyncVoid: (fn: () => Promise<void>) => fn,
}));

jest.mock("$app/utils/request", () => ({
  assertResponseError: jest.fn(),
  request: jest.fn(),
}));

// Mock Routes
declare global {
  // eslint-disable-next-line no-var
  var Routes: Record<string, () => string>;
}
global.Routes = {
  settings_payments_path: () => "/settings/payments",
};

describe("BalancePage", () => {
  const mockProps = {
    next_payout_period_data: null,
    processing_payout_periods_data: [],
    payouts_status: "payable" as const,
    past_payout_period_data: [],
    instant_payout: null,
    show_instant_payouts_notice: false,
    pagination: { page: 1, pages: 1, per_page: 10, total: 0 },
  };

  it("renders without crashing", () => {
    render(<BalancePage {...mockProps} />);
    expect(screen.getByRole("main")).toBeInTheDocument();
    expect(screen.getByText("Payouts")).toBeInTheDocument();
  });

  it("shows payout failure banner when payout_note contains 'failed'", () => {
    const propsWithFailure = {
      ...mockProps,
      next_payout_period_data: {
        status: "payable",
        payout_note: "Payout via Stripe failed because insufficient funds. Solution: Update your bank account.",
        has_stripe_connect: false,
        should_be_shown_currencies_always: false,
        displayable_payout_period_range: "Jan 1 - Jan 7, 2025",
        payout_currency: "usd",
        payout_cents: 10000,
        payout_displayed_amount: "$100.00",
        payout_date_formatted: "January 15th, 2025",
        payout_method_type: "none" as const,
        sales_cents: 12000,
        refunds_cents: 1000,
        chargebacks_cents: 500,
        credits_cents: 0,
        fees_cents: 500,
        discover_fees_cents: 300,
        direct_fees_cents: 200,
        discover_sales_count: 5,
        direct_sales_count: 3,
        taxes_cents: 0,
        affiliate_credits_cents: 0,
        affiliate_fees_cents: 0,
        paypal_payout_cents: 0,
        stripe_connect_payout_cents: 0,
        loan_repayment_cents: 0,
      },
    };

    render(<BalancePage {...propsWithFailure} />);

    // Check that the failure banner is present
    expect(screen.getByRole("alert")).toBeInTheDocument();
    expect(screen.getByText("A recent payout attempt failed.")).toBeInTheDocument();
    expect(screen.getByText(/Payout via Stripe failed because insufficient funds/u)).toBeInTheDocument();
  });

  it("does not show payout failure banner when payout_note does not contain 'failed'", () => {
    const propsWithNormalNote = {
      ...mockProps,
      next_payout_period_data: {
        status: "payable",
        payout_note: "Your next payout will be processed on January 15th.",
        has_stripe_connect: false,
        should_be_shown_currencies_always: false,
        displayable_payout_period_range: "Jan 1 - Jan 7, 2025",
        payout_currency: "usd",
        payout_cents: 10000,
        payout_displayed_amount: "$100.00",
        payout_date_formatted: "January 15th, 2025",
        payout_method_type: "none" as const,
        sales_cents: 12000,
        refunds_cents: 1000,
        chargebacks_cents: 500,
        credits_cents: 0,
        fees_cents: 500,
        discover_fees_cents: 300,
        direct_fees_cents: 200,
        discover_sales_count: 5,
        direct_sales_count: 3,
        taxes_cents: 0,
        affiliate_credits_cents: 0,
        affiliate_fees_cents: 0,
        paypal_payout_cents: 0,
        stripe_connect_payout_cents: 0,
        loan_repayment_cents: 0,
      },
    };

    render(<BalancePage {...propsWithNormalNote} />);

    // Check that no failure banner is present
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByText("A recent payout attempt failed.")).not.toBeInTheDocument();
  });

  it("does not show payout failure banner when payout_note is null", () => {
    const propsWithNullNote = {
      ...mockProps,
      next_payout_period_data: {
        status: "payable",
        payout_note: null,
        has_stripe_connect: false,
        should_be_shown_currencies_always: false,
        displayable_payout_period_range: "Jan 1 - Jan 7, 2025",
        payout_currency: "usd",
        payout_cents: 10000,
        payout_displayed_amount: "$100.00",
        payout_date_formatted: "January 15th, 2025",
        payout_method_type: "none" as const,
        sales_cents: 12000,
        refunds_cents: 1000,
        chargebacks_cents: 500,
        credits_cents: 0,
        fees_cents: 500,
        discover_fees_cents: 300,
        direct_fees_cents: 200,
        discover_sales_count: 5,
        direct_sales_count: 3,
        taxes_cents: 0,
        affiliate_credits_cents: 0,
        affiliate_fees_cents: 0,
        paypal_payout_cents: 0,
        stripe_connect_payout_cents: 0,
        loan_repayment_cents: 0,
      },
    };

    render(<BalancePage {...propsWithNullNote} />);

    // Check that no failure banner is present
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByText("A recent payout attempt failed.")).not.toBeInTheDocument();
  });
});
