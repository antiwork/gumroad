import * as React from "react";
import { cast } from "ts-safe-cast";

import { exportPayouts } from "$app/data/balance";
import { createInstantPayout } from "$app/data/payout";
import { formatPriceCentsWithCurrencySymbol, formatPriceCentsWithoutCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { PaginationProps } from "$app/components/Pagination";
import { ExportPayoutsPopover } from "$app/components/Payouts/ExportPayoutsPopover";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import Placeholder from "$app/components/ui/Placeholder";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/payouts.png";

const INSTANT_PAYOUT_FEE_PERCENTAGE = 0.03;
const MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS = 1000;
const MAXIMUM_INSTANT_PAYOUT_AMOUNT_CENTS = 999900;

type StripeConnectAccount = { payout_method_type: "stripe_connect"; stripe_connect_account_id: string };
type NoPayoutAccount = { payout_method_type: "none" };

// Some past payouts have no associated payout accounts, which is a different state than no (current) payout account
type LegacyNotAvailableAccount = { payout_method_type: "legacy-na" };

export type BankAccount =
  | {
      payout_method_type: "bank";
      bank_account_type: "ACH";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "AE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AR"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "AUSTRALIAN";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
      bsb_number: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "BG"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "CANADIAN";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
      transit_number: string;
      institution_number: string;
    }
  | {
      payout_method_type: "bank";
      bank_account_type: "CARD";
      routing_number: string;
      account_number: string;
      bank_name?: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "CH"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CZ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DK"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EU"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "HK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "HU"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IL"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KR"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MX"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NZ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PL"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RO"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TR"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "VN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ET"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ID"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "ZA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KE"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CR"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NO"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RS"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CL"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LI"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JP"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "EC"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "UY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MU"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "OM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "UZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "RW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "TN"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "JO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AL"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NE"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "NG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MD"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PA"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SV"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "PY"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "AM"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LK"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BD"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BT"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KW"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MG"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "IS"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "QA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BS"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "LC"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "SN"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "KH"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MN"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "DZ"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MO"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "BJ"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "CI"; account_number: string }
  | {
      payout_method_type: "bank";
      bank_account_type: "UK";
      bank_number: string;
      routing_number: string;
      account_number: string;
      bank_name?: string;
      sort_code: string;
    }
  | { payout_method_type: "bank"; bank_account_type: "GI"; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "GA"; routing_number: string; account_number: string }
  | { payout_method_type: "bank"; bank_account_type: "MC"; account_number: string };

export type PaypalAccount = { payout_method_type: "paypal"; paypal_address: string };

type CurrentPayoutsDataWithUserNotPayable = {
  status: "not_payable";
  should_be_shown_currencies_always: boolean;
  minimum_payout_amount_cents: number;
  payout_note?: string | null;
  has_stripe_connect: boolean;
};

type CurrentPayoutStatus = "paused" | "payable" | "processing" | "completed";
type PayoutType = "standard" | "instant";

type CurrentPeriodPayoutData = (
  | { status: "processing"; payment_external_id: string; arrival_date: string | null; type: PayoutType }
  | { status: Exclude<CurrentPayoutStatus, "processing" | "completed"> }
) & {
  has_stripe_connect: boolean;
  should_be_shown_currencies_always: boolean;
  displayable_payout_period_range: string;
  payout_currency: string;
  payout_cents: number;
  payout_displayed_amount: string;
  payout_date_formatted: string;
  sales_cents: number;
  refunds_cents: number;
  chargebacks_cents: number;
  credits_cents: number;
  fees_cents: number;
  discover_fees_cents: number;
  direct_fees_cents: number;
  discover_sales_count: number;
  direct_sales_count: number;
  taxes_cents: number;
  affiliate_credits_cents: number;
  affiliate_fees_cents: number;
  paypal_payout_cents: number;
  stripe_connect_payout_cents: number;
  loan_repayment_cents: number;
  payout_note?: string | null;
};

type PastPeriodPayoutsData = {
  status: "completed";
  should_be_shown_currencies_always: boolean;
  displayable_payout_period_range: string;
  payout_currency: string;
  payout_cents: number;
  payout_displayed_amount: string;
  is_processing: boolean;
  arrival_date: string | null;
  payment_external_id: string;
  payout_date_formatted: string;
  sales_cents: number;
  refunds_cents: number;
  chargebacks_cents: number;
  credits_cents: number;
  fees_cents: number;
  discover_fees_cents: number;
  direct_fees_cents: number;
  discover_sales_count: number;
  direct_sales_count: number;
  taxes_cents: number;
  affiliate_credits_cents: number;
  affiliate_fees_cents: number;
  paypal_payout_cents: number;
  stripe_connect_payout_cents: number;
  loan_repayment_cents: number;
  type: PayoutType;
};

export type PayoutsProps = {
  next_payout_period_data:
    | CurrentPayoutsDataWithUserNotPayable
    | CurrentPayoutsDataAndPaymentMethodWithUserPayable
    | null;
  processing_payout_periods_data: PayoutPeriodData[];
  payouts_status: "paused" | "payable";
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  payouts_paused_for_reason: string | null;
  past_payout_period_data: PayoutPeriodData[];
  instant_payout: {
    payable_amount_cents: number;
    payable_balances: {
      id: string;
      date: string;
      amount_cents: number;
    }[];
    bank_account_type: string;
    bank_name: string | null;
    routing_number: string;
    account_number: string;
  } | null;
  show_instant_payouts_notice: boolean;
  pagination: PaginationProps;
};

// TODO: move BankAccount|PaypalAccount out of CurrentPayoutsDataAndPaymentMethodWithUserPayable
export type CurrentPayoutsDataAndPaymentMethodWithUserPayable = CurrentPeriodPayoutData &
  (NoPayoutAccount | BankAccount | PaypalAccount | StripeConnectAccount);

// TODO: move BankAccount|PaypalAccount out of PastPayoutsDataAndPaymentMethod
export type PastPayoutsDataAndPaymentMethod = PastPeriodPayoutsData &
  (LegacyNotAvailableAccount | BankAccount | PaypalAccount | StripeConnectAccount);

type PayoutPeriodData = CurrentPayoutsDataAndPaymentMethodWithUserPayable | PastPayoutsDataAndPaymentMethod;
const Period = ({ payoutPeriodData }: { payoutPeriodData: PayoutPeriodData }) => {
  const { should_be_shown_currencies_always: showUSDSuffix } = payoutPeriodData;
  const [isCSVDownloadInProgress, setIsCSVDownloadInProgress] = React.useState(false);

  const formatDollarAmount = (amount: number) =>
    `${formatPriceCentsWithCurrencySymbol("usd", Math.abs(amount), {
      symbolFormat: "short",
      noCentsIfWhole: false,
    })} ${showUSDSuffix ? "USD" : ""}`;

  const formatNegativeDollarAmount = (amount: number) => `- ${formatDollarAmount(amount)}`;

  const handleRequestPayoutCSV = asyncVoid(async () => {
    if (!("payment_external_id" in payoutPeriodData)) {
      showAlert("Sorry, something went wrong. Please try again.", "error");
      return;
    }

    setIsCSVDownloadInProgress(true);

    try {
      await exportPayouts([payoutPeriodData.payment_external_id]);
      showAlert("You will receive an email in your inbox shortly with the data you've requested.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
    setIsCSVDownloadInProgress(false);
  });

  function currentPayoutHeading(payoutStatus: CurrentPayoutStatus, payoutDateFormatted: string) {
    switch (payoutStatus) {
      case "processing":
        return `Payout initiated on ${payoutDateFormatted}`;
      case "payable":
        return `Next payout: ${payoutDateFormatted}`;
      case "paused":
        return "Next payout: paused";
      case "completed":
        return payoutDateFormatted;
    }
  }

  const heading = currentPayoutHeading(payoutPeriodData.status, payoutPeriodData.payout_date_formatted);

  return (
    <section aria-label="Payout period">
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: "var(--spacer-4)",
        }}
      >
        {payoutPeriodData.status === "completed" ? <span>{heading}</span> : <h2>{heading}</h2>}
        {"type" in payoutPeriodData && payoutPeriodData.type === "instant" ? (
          <div className="pill small">Instant</div>
        ) : null}
        <span style={{ marginLeft: "auto" }}>{payoutPeriodData.displayable_payout_period_range}</span>
        {payoutPeriodData.status === "completed" && payoutPeriodData.payment_external_id ? (
          <WithTooltip position="top" tip="Export">
            <Button
              color="primary"
              disabled={isCSVDownloadInProgress}
              onClick={handleRequestPayoutCSV}
              aria-label="Export"
            >
              <Icon name="download" />
            </Button>
          </WithTooltip>
        ) : null}
      </div>
      <div className="stack" style={{ marginTop: "var(--spacer-4)" }}>
        <div>
          <h4>Sales</h4>
          <div>{formatDollarAmount(payoutPeriodData.sales_cents)}</div>
        </div>
        {payoutPeriodData.credits_cents > 0 ? (
          <div>
            <h4>Credits</h4>
            <div>{formatDollarAmount(payoutPeriodData.credits_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.affiliate_credits_cents !== 0 ? (
          <div>
            <h4>Affiliate or collaborator fees received</h4>
            <div>{formatDollarAmount(payoutPeriodData.affiliate_credits_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.discover_fees_cents !== 0 || payoutPeriodData.direct_fees_cents !== 0 ? (
          <>
            {payoutPeriodData.discover_fees_cents !== 0 ? (
              <div>
                <div>
                  <h4>
                    Discover sales{" "}
                    <a href="/help/article/66-gumroads-fees" target="_blank" rel="noreferrer">
                      fees
                    </a>
                  </h4>
                  {payoutPeriodData.discover_sales_count > 0 ? (
                    <small>
                      on {payoutPeriodData.discover_sales_count}{" "}
                      {payoutPeriodData.discover_sales_count === 1 ? "sale" : "sales"}
                    </small>
                  ) : null}
                </div>
                <div>{formatNegativeDollarAmount(payoutPeriodData.discover_fees_cents)}</div>
              </div>
            ) : null}
            {payoutPeriodData.direct_fees_cents !== 0 ? (
              <div>
                <div>
                  <h4>
                    Direct sales{" "}
                    <a href="/help/article/66-gumroads-fees" target="_blank" rel="noreferrer">
                      fees
                    </a>
                  </h4>
                  {payoutPeriodData.direct_sales_count > 0 ? (
                    <small>
                      on {payoutPeriodData.direct_sales_count}{" "}
                      {payoutPeriodData.direct_sales_count === 1 ? "sale" : "sales"}
                    </small>
                  ) : null}
                </div>
                <div>{formatNegativeDollarAmount(payoutPeriodData.direct_fees_cents)}</div>
              </div>
            ) : null}
          </>
        ) : (
          <div>
            <h4>
              <a href="/help/article/66-gumroads-fees" target="_blank" rel="noreferrer">
                Fees
              </a>
            </h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.fees_cents)}</div>
          </div>
        )}
        {payoutPeriodData.refunds_cents !== 0 ? (
          <div>
            <h4>Refunds</h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.refunds_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.chargebacks_cents !== 0 ? (
          <div>
            <h4>
              <a href="/help/article/134-how-does-gumroad-handle-chargebacks" target="_blank" rel="noreferrer">
                Chargebacks
              </a>
            </h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.chargebacks_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.credits_cents < 0 ? (
          <div>
            <h4>
              <a href="/help/article/269-balance-page" target="_blank" rel="noreferrer">
                Credits
              </a>
            </h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.credits_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.loan_repayment_cents !== 0 ? (
          <div>
            <h4>Loan repayments</h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.loan_repayment_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.affiliate_fees_cents !== 0 ? (
          <div>
            <h4>Affiliate or collaborator fees paid</h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.affiliate_fees_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.paypal_payout_cents !== 0 ? (
          <div>
            <h4>
              <a href="/help/article/275-paypal-connect" target="_blank" rel="noreferrer">
                PayPal payouts
              </a>
            </h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.paypal_payout_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.stripe_connect_payout_cents !== 0 ? (
          <div>
            <h4>
              <a href="/help/article/330-stripe-connect" target="_blank" rel="noreferrer">
                Stripe Connect payouts
              </a>
            </h4>
            <div>{formatNegativeDollarAmount(payoutPeriodData.stripe_connect_payout_cents)}</div>
          </div>
        ) : null}
        {payoutPeriodData.taxes_cents !== 0 ? (
          <div>
            <h4>
              <a href="/help/article/121-sales-tax-on-gumroad" target="_blank" rel="noreferrer">
                Taxes
              </a>
            </h4>
            <div>
              <WithTooltip
                position="top"
                tip="Gumroad does not collect tax for you; this is a calculation to help you with remittance."
              >
                <span>{formatDollarAmount(payoutPeriodData.taxes_cents)}</span>
              </WithTooltip>
            </div>
          </div>
        ) : null}
        <div>
          {(() => {
            const isCurrentPeriod = payoutPeriodData.status === "payable";
            switch (payoutPeriodData.payout_method_type) {
              case "stripe_connect":
                return (
                  <PeriodStripeConnectAccount
                    isCurrentPeriod={isCurrentPeriod}
                    stripeConnectAccount={payoutPeriodData}
                  />
                );
              case "bank":
                return <PeriodBankAccount isCurrentPeriod={isCurrentPeriod} bankAccount={payoutPeriodData} />;
              case "paypal":
                return <PeriodPaypalAccount isCurrentPeriod={isCurrentPeriod} paypalAccount={payoutPeriodData} />;
              case "legacy-na":
              case "none":
                return <PeriodNoAccount />;
            }
          })()}
          <div className="payout-amount">
            <span>
              {payoutPeriodData.payout_displayed_amount}
              {payoutPeriodData.status === "payable" && payoutPeriodData.should_be_shown_currencies_always ? "USD" : ""}
            </span>
          </div>
        </div>
      </div>
    </section>
  );
};

const PeriodEmpty = ({ minimumPayoutAmountCents }: { minimumPayoutAmountCents: number }) => (
  <div className="period period-empty full column">
    <Placeholder>
      <figure>
        <img src={placeholder} />
      </figure>
      <h2>Let's get you paid.</h2>
      Reach a balance of at least{" "}
      {formatPriceCentsWithCurrencySymbol("usd", minimumPayoutAmountCents, {
        symbolFormat: "short",
      })}{" "}
      to be paid out for your sales.
      <NavigationButton color="accent" href="/help/article/269-balance-page">
        Learn about payouts
      </NavigationButton>
    </Placeholder>
  </div>
);

const PeriodStripeConnectAccount = ({
  isCurrentPeriod,
  stripeConnectAccount,
}: {
  isCurrentPeriod: boolean;
  stripeConnectAccount: StripeConnectAccount & { payout_currency: string };
}) => (
  <h4>
    {isCurrentPeriod
      ? stripeConnectAccount.payout_currency.toUpperCase() !== "USD"
        ? `Will be converted to ${stripeConnectAccount.payout_currency.toUpperCase()} and sent to:`
        : "Will be sent to:"
      : null}{" "}
    {"Stripe account: "}
    <a href={`https://dashboard.stripe.com/${stripeConnectAccount.stripe_connect_account_id}`}>
      {stripeConnectAccount.stripe_connect_account_id}
    </a>
  </h4>
);

const PeriodBankAccount = ({
  isCurrentPeriod,
  bankAccount,
}: {
  isCurrentPeriod: boolean;
  bankAccount: BankAccount & { arrival_date?: string | null; status?: string; payout_currency: string };
}) => (
  <div style={{ display: "flex", flexDirection: "column", gap: "var(--spacer-2)" }}>
    <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}>
      {bankAccount.arrival_date ? (
        <Icon name={bankAccount.status === "completed" ? "solid-check-circle" : "outline-clock"} />
      ) : null}
      <h4>
        {bankAccount.arrival_date ? (
          <>
            {bankAccount.status === "completed" ? "Deposited " : "Expected deposit "}
            {"bank_name" in bankAccount && <span>to {bankAccount.bank_name} </span>}
            <span>on {bankAccount.arrival_date}</span>
          </>
        ) : (
          <>
            {isCurrentPeriod
              ? bankAccount.payout_currency.toUpperCase() !== "USD"
                ? `Will be converted to ${bankAccount.payout_currency.toUpperCase()} and sent to: `
                : "Will be sent to: "
              : null}
            {"bank_name" in bankAccount && <span>{bankAccount.bank_name}</span>}
          </>
        )}
      </h4>
    </div>
    <p className="text-xs">
      {bankAccount.bank_account_type === "CANADIAN" ? (
        <>
          <span>
            Transit number: <span>{bankAccount.transit_number}</span>
          </span>{" "}
          <span>
            Institution number: <span>{bankAccount.institution_number}</span>
          </span>
        </>
      ) : bankAccount.bank_account_type === "CARD" ? (
        <span>
          Card: <span>{bankAccount.routing_number}</span>
        </span>
      ) : "routing_number" in bankAccount ? (
        <span>
          Routing number: <span>{bankAccount.routing_number}</span>
        </span>
      ) : null}{" "}
      {"account_number" in bankAccount ? (
        <span>
          Account: <span>{bankAccount.account_number}</span>
        </span>
      ) : null}
    </p>
  </div>
);

const PeriodPaypalAccount = ({
  isCurrentPeriod,
  paypalAccount,
}: {
  isCurrentPeriod: boolean;
  paypalAccount: PaypalAccount;
}) => (
  <h4>
    {isCurrentPeriod ? "Will be sent to Paypal account:" : "Sent to Paypal account:"}{" "}
    <span>{paypalAccount.paypal_address}</span>
  </h4>
);

const PeriodNoAccount = () => <h4>Will be sent to:</h4>;

const Payouts = ({
  next_payout_period_data,
  processing_payout_periods_data,
  payouts_status,
  payouts_paused_by,
  payouts_paused_for_reason,
  past_payout_period_data,
  instant_payout,
  show_instant_payouts_notice,
  pagination: initialPagination,
}: PayoutsProps) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();

  const [pastPayoutPeriodData, setPastPayoutPeriodData] = React.useState(past_payout_period_data);
  const [pagination, setPagination] = React.useState(initialPagination);

  const [isLoading, setIsLoading] = React.useState(false);

  const loadNextPage = async () => {
    setIsLoading(true);
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: Routes.payments_paged_path({ page: pagination.page + 1 }),
      })
        .then((res) => res.json())
        .then((json) => cast<{ payouts: PayoutPeriodData[]; pagination: PaginationProps }>(json));

      setPastPayoutPeriodData((prevData) => [...prevData, ...response.payouts]);
      setPagination(response.pagination);
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const [isInstantPayoutModalOpen, setIsInstantPayoutModalOpen] = React.useState(false);
  const [instantPayoutId, setInstantPayoutId] = React.useState<string>(instant_payout?.payable_balances[0]?.id ?? "");
  const instantPayoutAmountCents =
    instant_payout?.payable_balances.reduce((sum, balance) => {
      const selectedBalance = instant_payout.payable_balances.find((b) => b.id === instantPayoutId);
      return selectedBalance && balance.date <= selectedBalance.date ? sum + balance.amount_cents : sum;
    }, 0) ?? 0;
  const instantPayoutFee = instant_payout
    ? instantPayoutAmountCents - Math.floor(instantPayoutAmountCents / (1 + INSTANT_PAYOUT_FEE_PERCENTAGE))
    : 0;
  const onRequestInstantPayout = async () => {
    if (!instant_payout) return;
    setIsLoading(true);
    try {
      await createInstantPayout(
        instant_payout.payable_balances.find((balance) => balance.id === instantPayoutId)?.date ??
          new Date().toISOString(),
      );
      window.location.reload();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsInstantPayoutModalOpen(false);
      setIsLoading(false);
    }
  };

  if (!loggedInUser) return null;

  const settingsAction = loggedInUser.policies.settings_payments_user.show ? (
    <NavigationButton href={Routes.settings_payments_path()}>
      <Icon name="gear-fill" />
      Settings
    </NavigationButton>
  ) : null;

  const bulkExportAction = loggedInUser.policies.balance.export ? <ExportPayoutsPopover /> : null;

  return (
    <div>
      <PageHeader
        title="Payouts"
        actions={
          settingsAction || bulkExportAction ? (
            <div className="flex gap-2">
              {settingsAction}
              {bulkExportAction}
            </div>
          ) : undefined
        }
      />
      <div className="space-y-8 p-4 md:p-8">
        {!instant_payout ? (
          show_instant_payouts_notice ? (
            <div className="info" role="status">
              <p>
                To enable <strong>instant</strong> payouts,{" "}
                <a href={Routes.settings_payments_path()}>update your payout method</a> to one of the{" "}
                <a href="https://docs.stripe.com/payouts/instant-payouts-banks">
                  supported bank accounts or debit cards
                </a>
                .
              </p>
            </div>
          ) : null
        ) : instant_payout.payable_amount_cents >= MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS ? (
          <div className="info" role="status">
            <div>
              <b>
                You have{" "}
                {formatPriceCentsWithCurrencySymbol("usd", instant_payout.payable_amount_cents, {
                  symbolFormat: "short",
                  noCentsIfWhole: false,
                })}{" "}
                available for instant payout:
              </b>{" "}
              No need to wait—get paid now!
              <div style={{ marginTop: "var(--spacer-3)" }}>
                {instant_payout.payable_balances.some(
                  (balance) => balance.amount_cents > MAXIMUM_INSTANT_PAYOUT_AMOUNT_CENTS,
                ) ? (
                  <a href={Routes.support_index_path()}>Contact us for an instant payout</a>
                ) : (
                  <Button
                    small
                    color="primary"
                    aria-label="Get paid now"
                    onClick={() => setIsInstantPayoutModalOpen(true)}
                  >
                    Get paid!
                  </Button>
                )}
              </div>
            </div>
            <Modal
              open={isInstantPayoutModalOpen}
              onClose={() => setIsInstantPayoutModalOpen(false)}
              footer={
                <>
                  <Button onClick={() => setIsInstantPayoutModalOpen(false)}>Cancel</Button>
                  <Button color="primary" disabled={isLoading} onClick={() => void onRequestInstantPayout()}>
                    Get paid!
                  </Button>
                </>
              }
              title="Instant payout"
            >
              <p>
                You can request instant payouts 24/7, including weekends and holidays. Funds typically appear in your
                bank account within 30 minutes, though some payouts may take longer to be credited.
              </p>

              <fieldset>
                <label htmlFor="instant-payout-date">Pay out balance up to</label>
                <div className="input cursor-pointer">
                  <Icon name="calendar-all" />
                  <select
                    id="instant-payout-date"
                    value={instantPayoutId}
                    onChange={(e) => setInstantPayoutId(e.target.value)}
                  >
                    {instant_payout.payable_balances.map((balance) => (
                      <option key={balance.id} value={balance.id}>
                        {new Date(balance.date).toLocaleDateString(userAgentInfo.locale, {
                          month: "long",
                          day: "numeric",
                          year: "numeric",
                        })}
                      </option>
                    ))}
                  </select>
                  <Icon name="outline-cheveron-down" />
                </div>
              </fieldset>
              <fieldset>
                <legend>Payout details</legend>
                <div className="cart">
                  <div className="cart-summary">
                    <div>
                      <p>Sent to</p>
                      <div>
                        {instant_payout.bank_account_type === "CARD" ? (
                          <p>
                            <span>
                              {instant_payout.routing_number} {instant_payout.account_number}
                            </span>
                          </p>
                        ) : (
                          <div>
                            {instant_payout.bank_name ? <p className="text-right">{instant_payout.bank_name}</p> : null}
                            <p className="text-right">
                              Routing number: <span>{instant_payout.routing_number}</span>
                            </p>
                            <p className="text-right">
                              Account: <span>{instant_payout.account_number}</span>
                            </p>
                          </div>
                        )}
                      </div>
                    </div>
                    <div>
                      <p>Amount</p>
                      <div>${formatPriceCentsWithoutCurrencySymbol("usd", instantPayoutAmountCents)}</div>
                    </div>
                    <div>
                      <p>Instant payout fee ({INSTANT_PAYOUT_FEE_PERCENTAGE * 100}%)</p>
                      <div>
                        -$
                        {formatPriceCentsWithoutCurrencySymbol("usd", instantPayoutFee)}
                      </div>
                    </div>
                  </div>
                  <footer>
                    <p>
                      <strong>You'll receive</strong>
                    </p>
                    <div>
                      ${formatPriceCentsWithoutCurrencySymbol("usd", instantPayoutAmountCents - instantPayoutFee)}
                    </div>
                  </footer>
                </div>
                {instantPayoutAmountCents > MAXIMUM_INSTANT_PAYOUT_AMOUNT_CENTS ? (
                  <div role="status" className="info">
                    Your balance exceeds the maximum amount for a single instant payout, so we'll automatically split
                    your balance into multiple payouts.
                  </div>
                ) : null}
              </fieldset>
            </Modal>
          </div>
        ) : null}
        {payouts_status === "paused" ? (
          <div className="warning" role="status">
            <p>
              {payouts_paused_by === "stripe" ? (
                <strong>
                  Your payouts are currently paused by our payment processor. Please check your{" "}
                  <a href="/settings/payments">Payment Settings</a> for any verification requirements.
                </strong>
              ) : payouts_paused_by === "admin" ? (
                <strong>
                  Your payouts have been paused by Gumroad admin.
                  {payouts_paused_for_reason ? ` Reason for pause: ${payouts_paused_for_reason}` : null}
                </strong>
              ) : payouts_paused_by === "system" ? (
                <strong>
                  Your payouts have been automatically paused for a security review and will be resumed once the review
                  completes.
                </strong>
              ) : (
                <strong>
                  You have paused your payouts. Please go to <a href="/settings/payments">Payment Settings</a> to resume
                  payouts.
                </strong>
              )}
            </p>
          </div>
        ) : null}
        {next_payout_period_data != null ? (
          next_payout_period_data.has_stripe_connect ? (
            <div className="info" role="status">
              <p>For Stripe Connect users, all future payouts will be deposited directly to your Stripe account</p>
            </div>
          ) : (
            <section className="grid gap-4">
              {next_payout_period_data.payout_note &&
              !["processing", "paused"].includes(next_payout_period_data.status) ? (
                <div className="info" role="status">
                  <p>{next_payout_period_data.payout_note}</p>
                </div>
              ) : null}
              {next_payout_period_data.status === "not_payable" ? (
                pastPayoutPeriodData.length > 0 ? (
                  <div className="info" role="status">
                    <p>
                      Reach a balance of at least{" "}
                      {formatPriceCentsWithCurrencySymbol("usd", next_payout_period_data.minimum_payout_amount_cents, {
                        symbolFormat: "short",
                      })}{" "}
                      to be paid out for your sales.
                    </p>
                  </div>
                ) : (
                  <PeriodEmpty minimumPayoutAmountCents={next_payout_period_data.minimum_payout_amount_cents} />
                )
              ) : (
                <Period payoutPeriodData={next_payout_period_data} />
              )}
            </section>
          )
        ) : null}
        {processing_payout_periods_data.length > 0 ? (
          <section>
            <section className="paragraphs">
              {processing_payout_periods_data.map((processingPayoutPeriodData, idx) => (
                <Period key={idx} payoutPeriodData={processingPayoutPeriodData} />
              ))}
            </section>
          </section>
        ) : null}

        {pastPayoutPeriodData.length > 0 ? (
          <>
            <section>
              <h2>Past payouts</h2>
              <section className="paragraphs">
                {pastPayoutPeriodData.map((payoutPeriodData, idx) => (
                  <Period key={idx} payoutPeriodData={payoutPeriodData} />
                ))}
              </section>
            </section>
            {pagination.page < pagination.pages ? (
              <Button color="primary" onClick={() => void loadNextPage()} disabled={isLoading}>
                Show older payouts
              </Button>
            ) : null}
          </>
        ) : null}
      </div>
    </div>
  );
};

export default Payouts;
