// Canadian postal codes start with a "forward sortation area" (FSA) whose first
// letter identifies the province or territory. We use this to recover the
// province when a payment wallet (Apple Pay / Google Pay) shares the buyer's
// billing postal code but omits the state/province field, because Canadian
// sales tax rates depend on the province and the wallet checkout flow has no
// province input the buyer could fill in themselves.
const FSA_FIRST_LETTER_TO_PROVINCE: Record<string, string> = {
  A: "NL", // Newfoundland and Labrador
  B: "NS", // Nova Scotia
  C: "PE", // Prince Edward Island
  E: "NB", // New Brunswick
  G: "QC", // Quebec (eastern)
  H: "QC", // Quebec (metropolitan Montreal)
  J: "QC", // Quebec (western)
  K: "ON", // Ontario (eastern)
  L: "ON", // Ontario (central)
  M: "ON", // Ontario (metropolitan Toronto)
  N: "ON", // Ontario (southwestern)
  P: "ON", // Ontario (northern)
  R: "MB", // Manitoba
  S: "SK", // Saskatchewan
  T: "AB", // Alberta
  V: "BC", // British Columbia
  Y: "YT", // Yukon
  // "X" is shared by Nunavut and the Northwest Territories and is handled below.
};

// Nunavut's postal codes all begin with one of these three FSAs; every other
// "X" postal code belongs to the Northwest Territories.
const NUNAVUT_FSAS = new Set(["X0A", "X0B", "X0C"]);

// Province to elect when a Canadian buyer's real province cannot be determined
// at all (the wallet shared neither a state nor a usable postal code, and
// checkout has no prior Canadian province). Alberta charges only the 5%
// federal GST — the one component of Canadian sales tax every buyer owes no
// matter which province or territory they live in. Electing it means an
// unknown-province purchase still collects the federal portion, without
// charging the buyer another province's higher HST/PST or attributing
// provincial tax to a jurisdiction they may not be in.
export const GST_ONLY_FALLBACK_PROVINCE = "AB";

// Returns the two-letter Canadian province/territory code for a postal code,
// or null when the postal code doesn't look Canadian. Accepts the common
// formats buyers and wallets produce: "K1A 0B1", "k1a0b1", "K1A".
export const provinceForCanadianPostalCode = (postalCode: string | null | undefined): string | null => {
  const normalized = (postalCode ?? "").replace(/\s/gu, "").toUpperCase();
  if (!/^[A-Z]\d[A-Z]/u.test(normalized)) return null;
  const firstLetter = normalized[0] ?? "";
  if (firstLetter === "X") return NUNAVUT_FSAS.has(normalized.slice(0, 3)) ? "NU" : "NT";
  return FSA_FIRST_LETTER_TO_PROVINCE[firstLetter] ?? null;
};
