// Some payout countries are not in `country_supports_iban?` (so the payout settings form shows them
// the generic "Account #" box rather than the dedicated IBAN box), yet their bank-account models
// still require a specific format the generic box does not hint at. Morocco, for example, wants an
// IBAN-shaped value (MoroccoBankAccount's /\AMA[0-9]{26}\z/) and Gambia wants a fixed 18-character
// number (GambiaBankAccount's /^[0-9A-Za-z]{18}$/). Showing the generic "1234567890" hint there
// tells sellers to enter their short local account number, which is always rejected on save.
//
// This table is the one place that describes those formats to the browser. It feeds two things:
// the hint attributes on the account-number inputs (BankAccountSection) and the check that runs
// when the seller presses Save (validateBankAccountFields in pages/Settings/Payments/Show). Both
// are needed: the inputs carry a `pattern`, but the Save button posts through Inertia instead of
// submitting the form element, so the browser never enforces `pattern` on its own.
//
// Each `pattern` mirrors the country's bank-account model regex, and each placeholder is a value the
// model accepts. A placeholder must not be an account number Stripe reserves for tests: live mode
// refuses those, and a seller copying the hint cannot tell it apart from their own number.
//
// Deliberately no `maxLength` anywhere: the server strips separators before it validates (see
// normalizeAccountNumber below), so "12-3456-7890123-00" is a valid New Zealand entry even though
// it is longer than the 16 digits the model wants. A length cap sized to the bare number would
// silently swallow the last characters of a number pasted in that printed form.
export type CountryAccountNumberHint = {
  placeholder: string;
  pattern: string;
  // Doubles as the message the seller sees when their number does not match the pattern, so keep
  // it phrased as an instruction rather than a description of the regex.
  title: string;
  inputMode?: "numeric";
};

export const COUNTRY_ACCOUNT_NUMBER_HINTS: Record<string, CountryAccountNumberHint> = {
  MA: {
    placeholder: "MA64011519000001205000534921",
    pattern: "MA[0-9]{26}",
    title: "Enter your 28-character IBAN: MA followed by 26 digits, not your RIB",
  },
  SN: {
    placeholder: "SN08SN0100152000048500003035",
    pattern: "SN[0-9SN]{20,26}",
    title: "Enter your IBAN, starting with SN",
  },
  RS: {
    placeholder: "RS35260005601001611379",
    pattern: "RS[0-9]{18,20}",
    title: "Enter your IBAN, starting with RS",
  },
  MD: {
    placeholder: "MD24AG000225100013104168",
    pattern: "MD[0-9]{2}[A-Z0-9]{20}",
    title: "Enter your IBAN, starting with MD",
  },
  GM: {
    placeholder: "000123000456000789",
    pattern: "[0-9A-Za-z]{18}",
    title: "Enter your 18-character account number",
  },
  MZ: {
    placeholder: "001234567890123456789",
    pattern: "[0-9A-Za-z]{21}",
    title: "Enter your 21-character NIB, without the MZ IBAN prefix",
  },
  QA: {
    placeholder: "QA87CITI123456789012345678901",
    pattern: "[0-9A-Za-z]{29}",
    title: "Enter your 29-character IBAN, starting with QA",
  },
  MK: {
    placeholder: "MK49250120000058907",
    pattern: "[0-9A-Za-z]{19}",
    title: "Enter your 19-character IBAN, starting with MK",
  },
  GA: {
    placeholder: "00001234567890123456789",
    pattern: "[0-9]{23}",
    inputMode: "numeric",
    title: "Enter your 23-digit account number",
  },
  DZ: {
    placeholder: "00001234567890123456",
    pattern: "[0-9]{20}",
    inputMode: "numeric",
    title: "Enter your 20-digit RIB, digits only",
  },
  ET: {
    placeholder: "0000000012345",
    pattern: "[0-9A-Za-z]{13,16}",
    title: "Enter your 13 to 16 character account number",
  },
  BD: {
    placeholder: "1234567890123",
    pattern: "[0-9A-Za-z]{13,17}",
    title: "Enter your 13 to 17 character account number",
  },
  AM: {
    placeholder: "00001234567890",
    pattern: "[0-9]{11,16}",
    inputMode: "numeric",
    title: "Enter your 11 to 16 digit account number",
  },
  AR: {
    placeholder: "0110000600000000000000",
    pattern: "[0-9]{22}",
    inputMode: "numeric",
    title: "Enter your 22-digit CBU",
  },
  PE: {
    placeholder: "12345678901234567890",
    pattern: "[0-9]{20}",
    inputMode: "numeric",
    title: "Enter your 20-digit CCI",
  },
  MX: {
    placeholder: "032180000118359719",
    pattern: "[0-9]{18}",
    inputMode: "numeric",
    title: "Enter your 18-digit CLABE",
  },
  KR: {
    placeholder: "00012345678901",
    pattern: "[0-9]{11,16}",
    inputMode: "numeric",
    title: "Enter your 11 to 16 digit account number",
  },
  NZ: {
    placeholder: "1234567890123456",
    pattern: "[0-9]{15,16}",
    inputMode: "numeric",
    title: "Enter your 15 or 16 digit account number, including the bank and branch digits",
  },
  JP: {
    placeholder: "1234567",
    pattern: "[0-9]{4,8}",
    inputMode: "numeric",
    title: "Enter your 4 to 8 digit account number, without the bank or branch code",
  },
  GI: {
    placeholder: "01234567",
    pattern: "[0-9]{8}",
    inputMode: "numeric",
    title: "Enter your 8-digit account number",
  },
  // OmanBankAccount only runs its format check in production, so this is the one entry whose
  // pattern a local or CI run cannot cross-check against the model.
  OM: {
    placeholder: "123456789012",
    pattern: "[0-9]{6,16}",
    inputMode: "numeric",
    title: "Enter your 6 to 16 digit account number, not your IBAN",
  },
};

// Placeholder for the dedicated IBAN box shown to `country_supports_iban?` countries. Each value has
// the country's IBAN length and layout but "00" check digits, which no IBAN can carry, so it is never
// someone's real account. accountNumberFormatError refuses it verbatim, since a few models only check
// the shape and would otherwise save it over the seller's current payout account.
export const COUNTRY_IBAN_PLACEHOLDERS: Record<string, string> = {
  AE: "AE000331234567890123457",
  AL: "AL00212110090000000235698742",
  AO: "AO00004400006729503010103",
  AT: "AT001904300234573202",
  AZ: "AZ00NABZ00000000137010001945",
  BA: "BA001290079401028495",
  BE: "BE00539007547035",
  BG: "BG00BNBG96611020345679",
  BH: "BH00BMAG00001299123457",
  BJ: "BJ00BC0010100100045000000110",
  CH: "CH0000762011623852958",
  CI: "CI00CI0080111301134291200590",
  CR: "CR00015202001026284067",
  CY: "CY00002001280000001200527601",
  CZ: "CZ0008000000192000145400",
  DE: "DE00370400440532013001",
  DK: "DK0000400440116244",
  EE: "EE002200221020145686",
  EG: "EG000019000500000000263180003",
  ES: "ES0021000418450200051333",
  FI: "FI0012345600000786",
  FR: "FR0020041010050500013M02607",
  GR: "GR0001101250000000012300696",
  GT: "GT00TRAJ01020000001210029691",
  HR: "HR0010010051863000161",
  HU: "HU00117730161111101800000001",
  IE: "IE00AIBK93115212345679",
  IL: "IL000108000000099990000",
  IS: "IS000159260076545510730340",
  IT: "IT00X0542811101000000123457",
  JO: "JO00CBJO0010000000000131000303",
  KW: "KW00CBKU0000000000001234560102",
  KZ: "KZ00125KZT5004100101",
  LI: "LI00088100002324014AA",
  LT: "LT001000011101001001",
  LU: "LU000019400644750001",
  LV: "LV00BANK0000435195002",
  MC: "MC0011222000010123456789031",
  MG: "MG0000005030010101914016057",
  MT: "MT00MALT011000012345MTLCAST002S",
  MU: "MU00BOMM0101101030300200001MUR",
  NE: "NE00NE0380100100130305000269",
  NL: "NL00ABNA0417164301",
  NO: "NO0086011117948",
  PK: "PK00SCBL0000001123456703",
  PL: "PL00109010140000071219812875",
  PT: "PT00000201231234567890155",
  RO: "RO00AAAA1B31007593840001",
  SA: "SA0080000000608010167520",
  SE: "SE0050000000058398257467",
  SI: "SI00263300012039087",
  SK: "SK0012000000198742637542",
  SM: "SM00U0322509800000000270101",
  TN: "TN0010006035183598478832",
  TR: "TR000006100519786457841327",
};

// UpdatePayoutMethod strips these from the account number (and its confirmation) before it hands
// the value to the bank-account model, so a number entered in the grouped form banks print —
// "12-3456-7890123-00", or an IBAN in four-character blocks — saves fine today. Mirror that here
// so this check accepts everything the server accepts. Keep it in step with
// UpdatePayoutMethod::ACCOUNT_NUMBER_SEPARATOR_CHARACTERS (app/services/update_payout_method.rb):
// \p{Cf} covers invisible formatting characters that ride along in copied text, and \u0085 is in
// Ruby's [[:space:]] but not in JavaScript's \s, so it needs naming to match the server.
const ACCOUNT_NUMBER_SEPARATORS = /[\s\p{Cf}\u0085-]/gu;

export const normalizeAccountNumber = (value: string) => value.replace(ACCOUNT_NUMBER_SEPARATORS, "");

// Returns the seller-facing message to show when `accountNumber` cannot be saved for this country,
// or null when there is nothing to complain about — either because the number fits the country's
// format, or because we have no format on record for it and only the server can say.
export const accountNumberFormatError = (countryCode: string | null, accountNumber: string): string | null => {
  const ibanExample = countryCode ? COUNTRY_IBAN_PLACEHOLDERS[countryCode] : undefined;
  if (ibanExample && normalizeAccountNumber(accountNumber).toUpperCase() === ibanExample) {
    return "Enter your own IBAN. The one shown in the box is only an example.";
  }

  const hint = countryCode ? COUNTRY_ACCOUNT_NUMBER_HINTS[countryCode] : undefined;
  if (!hint) return null;

  // The browser anchors the `pattern` attribute implicitly; anchor it the same way here so the two
  // checks agree on what the same pattern string means.
  const pattern = new RegExp(`^(?:${hint.pattern})$`, "u");
  return pattern.test(normalizeAccountNumber(accountNumber)) ? null : hint.title;
};
