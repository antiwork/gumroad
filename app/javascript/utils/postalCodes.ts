// Countries whose official addressing format has no postal code at all, per the Universal Postal
// Union's country address templates. Sellers there have nothing valid to type, so we neither show
// the field nor require it, and the backend drops it before the address reaches Stripe (see
// StripeBeneficialOwnersManager::COUNTRIES_WITHOUT_POSTAL_CODE).
//
// BW = Botswana, GM = Gambia.
export const COUNTRIES_WITHOUT_POSTAL_CODE = ["BW", "GM"];

// An unknown country falls back to requiring a postal code, which is what the form did before this
// helper existed.
export const countryRequiresPostalCode = (countryCode: string | null | undefined) =>
  countryCode == null || !COUNTRIES_WITHOUT_POSTAL_CODE.includes(countryCode);
