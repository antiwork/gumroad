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

// Placeholder for the dedicated IBAN box shown to `country_supports_iban?` countries. Each value
// has the country's IBAN length, a real mod-97 check pair and a bank code Ibandit knows, so it
// passes the country's bank-account model — and none is one of Stripe's reserved test IBANs.
export const COUNTRY_IBAN_PLACEHOLDERS: Record<string, string> = {
  AE: "AE770331234567890123457",
  AL: "AL20212110090000000235698742",
  AO: "AO76004400006729503010103",
  AT: "AT341904300234573202",
  AZ: "AZ91NABZ00000000137010001945",
  BA: "BA121290079401028495",
  BE: "BE41539007547035",
  BG: "BG53BNBG96611020345679",
  BH: "BH40BMAG00001299123457",
  BJ: "BJ68BC0010100100045000000110",
  CH: "CH6600762011623852958",
  CI: "CI66CI0080111301134291200590",
  CR: "CR75015202001026284067",
  CY: "CY87002001280000001200527601",
  CZ: "CZ3808000000192000145400",
  DE: "DE62370400440532013001",
  DK: "DK2300400440116244",
  EE: "EE112200221020145686",
  EG: "EG110019000500000000263180003",
  ES: "ES6421000418450200051333",
  FI: "FI9112345600000786",
  FR: "FR8420041010050500013M02607",
  GR: "GR8601101250000000012300696",
  GT: "GT55TRAJ01020000001210029691",
  HR: "HR8210010051863000161",
  HU: "HU15117730161111101800000001",
  IE: "IE02AIBK93115212345679",
  IL: "IL840108000000099990000",
  IS: "IS840159260076545510730340",
  IT: "IT33X0542811101000000123457",
  JO: "JO67CBJO0010000000000131000303",
  KW: "KW54CBKU0000000000001234560102",
  KZ: "KZ59125KZT5004100101",
  LI: "LI69088100002324014AA",
  LT: "LT821000011101001001",
  LU: "LU980019400644750001",
  LV: "LV53BANK0000435195002",
  MC: "MC3111222000010123456789031",
  MG: "MG1900005030010101914016057",
  MT: "MT03MALT011000012345MTLCAST002S",
  MU: "MU64BOMM0101101030300200001MUR",
  NE: "NE31NE0380100100130305000269",
  NL: "NL64ABNA0417164301",
  NO: "NO6686011117948",
  PK: "PK09SCBL0000001123456703",
  PL: "PL34109010140000071219812875",
  PT: "PT23000201231234567890155",
  RO: "RO22AAAA1B31007593840001",
  SA: "SA7380000000608010167520",
  SE: "SE1850000000058398257467",
  SI: "SI29263300012039087",
  SK: "SK0412000000198742637542",
  SM: "SM59U0322509800000000270101",
  TN: "TN3210006035183598478832",
  TR: "TR060006100519786457841327",
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
  const hint = countryCode ? COUNTRY_ACCOUNT_NUMBER_HINTS[countryCode] : undefined;
  if (!hint) return null;

  // The browser anchors the `pattern` attribute implicitly; anchor it the same way here so the two
  // checks agree on what the same pattern string means.
  const pattern = new RegExp(`^(?:${hint.pattern})$`, "u");
  return pattern.test(normalizeAccountNumber(accountNumber)) ? null : hint.title;
};
