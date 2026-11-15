// The EU immediate-delivery / loss-of-withdrawal-right consent, introduced for Directive (EU)
// 2023/2673 and the Consumer Rights Directive (2011/83/EU) art. 16(m) (digital content) and
// art. 16(a) (services performed immediately). See the ruling on antiwork/gumroad-private#4574.
//
// This module is deliberately dependency-free at runtime: `Checkout/payment.ts` imports it for
// the submit-time validation, and the component imports `payment.ts` for its state, so anything
// imported here that reached back into payment.ts would close a cycle.

/**
 * Key the consent checkbox is stored under in `state.customFieldValues`. It reuses that map (and
 * the `set-custom-field` dispatch) rather than adding a field to the checkout reducer: the value
 * is a required checkbox exactly like a seller's `terms` custom field, and nothing serializes the
 * map wholesale — `buildCustomFieldValues` only ever looks up keys the product's own field
 * descriptors define, so this key never reaches the server as a custom field. The server reads
 * the value from the line item's `eu_withdrawal_consent` instead.
 */
export const EU_WITHDRAWAL_CONSENT_FIELD_KEY = "euWithdrawalConsent";

/**
 * The wording the buyer agrees to, and the version of it recorded on the purchase. Bump
 * `Purchase::EU_WITHDRAWAL_CONSENT_VERSION` in the same change that edits this string — the
 * version is what tells a later reader which text an earlier buyer actually saw.
 *
 * Keep the sentence limited to the statutory withdrawal right: it must not read as if Gumroad's
 * own refunds, chargebacks or dispute handling were unavailable (ToS §11.2(d)).
 */
export const EU_WITHDRAWAL_CONSENT_TEXT =
  "I want access to this product now and I understand that, as an EU consumer, I lose my 14-day right to withdraw from this purchase once it is delivered.";

/**
 * The consumers the Consumer Rights Directive's withdrawal right covers: the EU member states.
 * Keep in sync with `Compliance::Countries::EU_WITHDRAWAL_RIGHT_COUNTRY_CODES`
 * (lib/utilities/compliance/countries.rb) — the same kind of duplicated list as
 * `nameOfSalesTaxForCountry` in `Checkout/index.tsx`, which has the same keep-in-sync note.
 */
export const EU_WITHDRAWAL_RIGHT_COUNTRY_CODES = new Set([
  "AT", // Austria
  "BE", // Belgium
  "BG", // Bulgaria
  "HR", // Croatia
  "CY", // Cyprus
  "CZ", // Czechia
  "DK", // Denmark
  "EE", // Estonia
  "FI", // Finland
  "FR", // France
  "DE", // Germany
  "GR", // Greece
  "HU", // Hungary
  "IE", // Ireland
  "IT", // Italy
  "LV", // Latvia
  "LT", // Lithuania
  "LU", // Luxembourg
  "MT", // Malta
  "NL", // Netherlands
  "PL", // Poland
  "PT", // Portugal
  "RO", // Romania
  "SK", // Slovakia
  "SI", // Slovenia
  "ES", // Spain
  "SE", // Sweden
]);

/**
 * True when the cart needs the consent: the buyer is in an EU member state and at least one line
 * is not a physical good. Physical goods are excluded because their withdrawal right cannot be
 * waived, so a consent box there would state something untrue.
 *
 * Takes primitives rather than the checkout `State` so both the component and the submit-time
 * validation can call it without importing each other.
 */
export const euWithdrawalConsentApplies = (
  countryCode: string | null | undefined,
  nativeTypes: (string | null | undefined)[],
) =>
  !!countryCode &&
  EU_WITHDRAWAL_RIGHT_COUNTRY_CODES.has(countryCode) &&
  nativeTypes.some((type) => type !== "physical");
