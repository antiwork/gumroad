import typia from "typia";

import type { CurrencyCode } from "$app/utils/currency";
import { request, ResponseError } from "$app/utils/request";

export type GetSurchargesRequest = {
  products: {
    permalink: string;
    uid?: string | undefined;
    quantity: number;
    price: number;
    // The share of the buyer's tip included in `price`, so the server can carve it back out
    // when allocating the buyer-currency quote across the cart's lines and components.
    tip_cents: number;
    // Exact buyer-currency tip the buyer typed, when the checkout is already displaying an
    // FX quote. Optional for rolling deploy compatibility.
    presentment_tip_cents?: number | undefined;
    // Direct-listed Payment Elements charge in the product's listed currency. Send the
    // listed-currency line amount and tip so the surcharge response can return the same
    // per-line rounded total the charge path will later persist.
    listed_price_cents?: number | undefined;
    listed_tip_cents?: number | undefined;
    pay_in_installments?: boolean | undefined;
    subscription_id?: string | undefined;
  }[];
  postal_code?: string;
  country: string;
  state?: string;
  vat_id?: string;
  buyer_currency?: string;
  payment_details_source?: "payment_element" | "saved_payment_method" | undefined;
  payment_element_mount_currency?: string | null | undefined;
  payment_element_direct_listed_currency?: string | null | undefined;
  // Page-issued list token. Direct-listed allocations convert tax/shipping with
  // the rate signed into it so the Element total matches charge time.
  payment_method_list_token?: string | null | undefined;
};

export type DirectListedLineAllocation = {
  permalink: string;
  price_cents: number;
  tip_cents: number;
  tax_cents: number;
  shipping_cents: number;
  total_cents: number;
};

export type SurchargesResponse = {
  vat_id_valid: boolean;
  has_vat_id_input: boolean;
  shipping_rate_cents: number;
  tax_cents: number;
  tax_included_cents: number;
  subtotal: number;
  // The canonical-currency amount charged now. Optional for rolling deploy compatibility.
  charge_canonical_total_cents?: number | null | undefined;
  // Server-owned listed-currency split for direct-listed Payment Elements. The browser
  // sums this instead of converting aggregate USD tax/shipping, because charge time
  // converts each purchase separately and then sums the rounded components.
  direct_listed_line_allocations?: DirectListedLineAllocation[] | null | undefined;
  // Signed proof of the exact direct-listed split that mounted the Payment Element.
  direct_listed_amount_token?: string | null | undefined;
  // Absolute expiry of that token. Optional for rolling deploy with servers that omit it.
  direct_listed_amount_token_expires_at?: string | null | undefined;
  // Client deadline derived from the response's server clock, not the device's wall-clock offset.
  direct_listed_amount_token_client_expires_at?: number;
  buyer_currency_quote: {
    token: string;
    currency: CurrencyCode;
    canonical_total_cents: number;
    presentment_total_cents: number;
    // The exact local-currency amount charged now when the cart total is an agreement that
    // also includes a preorder, commission balance, or future installments.
    charge_presentment_total_cents?: number | undefined;
    // The sum of the fixed local-currency prices for every remaining installment.
    future_installments_presentment_total_cents?: number | undefined;
    // What one canonical US dollar cent is worth in the buyer's currency, used only for the
    // amounts the browser still converts itself (the discount row and the tip the buyer types).
    // A single-seller cart reports the exact rate from its one locked quote; a cart spanning
    // several sellers locks one quote per seller whose rates need not be identical, so it
    // reports what the locked totals imply instead. Every amount that is actually charged comes
    // from line_allocations.
    rate: number;
    subunit_to_unit: number;
    // The soonest expiry among the cart's locked quotes.
    expires_at: string;
    // Client deadline derived from the response's server clock, not the device's wall-clock offset.
    client_expires_at?: number;
    // The server-owned split of the locked presentment total across the request's product
    // lines, in request order, computed with the same largest-remainder rounding the charge
    // uses to persist purchase presentment rows. The checkout renders these amounts
    // verbatim so the visible lines always sum to the locked total and match the receipt.
    // Optional only for rolling deploy compatibility with servers that predate this field;
    // without it the browser treats the quote as unusable and stays in canonical currency.
    line_allocations?:
      | {
          permalink: string;
          price_cents: number;
          tip_cents: number;
          tax_cents: number;
          shipping_cents: number;
          total_cents: number;
        }[]
      | undefined;
  } | null;
  detected_buyer_currency?: string | null | undefined;
  available_buyer_currencies?: { code: string; label: string }[] | undefined;
};

export const getSurcharges = async (data: GetSurchargesRequest, abortSignal?: AbortSignal) => {
  const startedAt = Date.now();
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.customer_surcharges_path(),
    abortSignal,
    data,
  });
  if (!response.ok) throw new ResponseError();
  const result = typia.assert<SurchargesResponse>(await response.json());
  const serverTime = Date.parse(response.headers.get("Date") ?? "");
  if (result.buyer_currency_quote) {
    result.buyer_currency_quote.client_expires_at = clientExpiresAt(
      result.buyer_currency_quote.expires_at,
      startedAt,
      serverTime,
    );
  }
  if (result.direct_listed_amount_token) {
    // A rolling-deploy response can still omit expires_at. Do not treat that as already expired.
    result.direct_listed_amount_token_client_expires_at =
      result.direct_listed_amount_token_expires_at == null
        ? Number.MAX_SAFE_INTEGER
        : clientExpiresAt(result.direct_listed_amount_token_expires_at, startedAt, serverTime);
  }
  return result;
};

function clientExpiresAt(expiresAt: string, startedAt: number, serverTime: number) {
  if (!Number.isFinite(serverTime)) {
    // No trusted server clock. Do not derive expiry from the device clock — a clock that is
    // ≥1h fast would treat every fresh token as expired and loop local-currency checkout.
    // Leave it non-expiring client-side; the server still refuses a truly expired token.
    return Number.MAX_SAFE_INTEGER;
  }
  // Starting the lifetime at request start also deducts transit time. HTTP Date has
  // whole-second precision, so reserve that second rather than extending the token.
  return startedAt + Date.parse(expiresAt) - serverTime - 1000;
}
