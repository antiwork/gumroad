import { GST_ONLY_FALLBACK_PROVINCE, provinceForCanadianPostalCode } from "$app/utils/canadianPostalCodes";

// Applies a wallet's billing address to checkout's tax-location state. Shared by BOTH wallet
// surfaces — the standalone Payment Request Button and wallets rendered inside the Stripe
// Payment Element — so the tax-critical rules below can never drift between them.
//
// Honor the wallet's billing country for ALL countries, not just US. Checkout state
// defaults `country` to "US" when the account has no country and geo-detection fails,
// so without this a non-US Apple Pay / Google Pay buyer submits taxCountryElection "US"
// with an empty ZIP and the server's US-only ZIP validation rejects the purchase with
// "You entered a ZIP Code that doesn't exist within your country" — an error the buyer
// can't fix because the wallet flow never shows a ZIP field. The billing state/province
// is copied too because Canadian tax lookup requires it alongside the country. When the
// wallet omits a state we clear the field rather than keep the old value, so a stale
// province from a previous selection can't pair with the new country and produce a
// wrong tax calculation. For Canada specifically, some wallets share only the postal
// code without the province — since every Canadian postal code's first letter maps to
// exactly one province or territory, we derive the province from the postal code so
// Canadian tax can still be calculated (the wallet flow has no province field the
// buyer could fill in manually). If the wallet gives neither a state nor a usable
// Canadian postal code, we still must not submit a blank province: Canadian tax is only
// calculated when a province is present, so "CA" with an empty province would silently
// collect no tax, and the wallet flow gives the buyer no province field to correct it.
// In that case we keep the existing checkout state when the wallet's billing country
// matches the country checkout already had (it came from the buyer's saved address or
// geo-detection for that same country, so it isn't stale). As a true last resort for
// Canada — the wallet gave no province, no usable postal code, and checkout had no
// prior Canadian province — we elect Alberta. That choice is deliberate, not an
// arbitrary list default: Alberta charges only the 5% federal GST, which applies to
// buyers in every province and territory. Electing it when the real province is
// unknowable means we always collect the federal portion the buyer owes regardless of
// where they live, and we never charge them another province's higher HST/PST or remit
// provincial tax to a jurisdiction they may not be in.
// Returns whether applying the address changed checkout's tax location — mirroring exactly the
// conditions under which the checkout reducer invalidates the surcharges quote (a country
// change, ANY US ZIP change — the reducer does not require a completed 5-digit ZIP, so neither
// can we, or a wallet ZIP+4 like "10001-1234" would invalidate the quote while we report no
// change — or a Canadian province change). Callers holding a tokenized wallet payment use this
// to know the wallet-approved total may no longer match the recalculated charge and the
// submission must wait for the surcharges reload (see the held wallet submission handling in
// PaymentForm.tsx).
export const applyWalletBillingAddressToCheckout = (
  billingAddress: { country: string | null; postal_code: string | null; state: string | null } | null | undefined,
  checkout: { country: string; state: string; zipCode: string },
  dispatch: (action: {
    type: "set-wallet-billing-address";
    country: string;
    zipCode: string | undefined;
    state: string;
  }) => void,
): boolean => {
  if (!billingAddress?.country) return false;
  const billingState =
    billingAddress.state ||
    (billingAddress.country === "CA" ? provinceForCanadianPostalCode(billingAddress.postal_code) : null) ||
    (billingAddress.country === checkout.country ? checkout.state : null) ||
    (billingAddress.country === "CA" ? GST_ONLY_FALLBACK_PROVINCE : null);
  // When the wallet shares no postal code and the country isn't changing, keep checkout's
  // existing ZIP (same reasoning as keeping the existing state above: it belonged to this same
  // country, so it isn't stale). Clearing it instead would both needlessly invalidate the
  // surcharges quote (the reducer treats any US ZIP change — including clearing — as a
  // tax-location change) and, for US buyers, wipe a ZIP the server requires.
  const billingZipCode =
    billingAddress.postal_code || (billingAddress.country === checkout.country ? checkout.zipCode : undefined);
  // A single dedicated action rather than three "set-value" dispatches: the wallet's address
  // lands mid-payment (after the buyer approved the sheet), and the reducer's "set-value"
  // tax-location invalidation cancels an in-flight card payment back to "input" — which on the
  // Payment Element wallet lanes (where the wallet payment runs as paymentMethod "card") would
  // abort the held wallet payment before it could wait for the surcharges reload. The dedicated
  // action invalidates the quote without cancelling the pipeline; see the reducer case.
  dispatch({
    type: "set-wallet-billing-address",
    country: billingAddress.country,
    zipCode: billingZipCode,
    state: billingState ?? "",
  });
  // Each condition matches the reducer's surcharge-invalidation rule for the corresponding
  // field above, evaluated the way the reducer sees it (the fields land in one action, so the
  // ZIP and state rules key on the wallet's country). The US ZIP rule deliberately has no
  // length/format requirement — the reducer invalidates on ANY US ZIP change (partial ZIPs and
  // ZIP+4 included, since the server derives the taxable location from whatever ZIP is
  // submitted), so this must report those changes too or a held wallet payment would be
  // released against a stale quote.
  return (
    billingAddress.country !== checkout.country ||
    (billingAddress.country === "US" && billingZipCode !== checkout.zipCode) ||
    (billingAddress.country === "CA" && (billingState ?? "") !== checkout.state)
  );
};
