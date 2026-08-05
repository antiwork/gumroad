// Colombia issues two personal IDs: the Cédula de Ciudadanía to citizens and the Cédula de
// Extranjería to foreign residents. Both are sent to Stripe as individual.id_number, and Stripe
// enforces 6-10 digits on that field for CO. They widened the floor from 7 on 2026-08-05 (support
// case sco_UyXAayCkurHzCd) after it refused a real 6-digit Cédula de Extranjería; both endpoints
// were re-derived live that day. Test-mode Stripe does NOT enforce this, so a local probe accepts
// any length and cannot be used to re-derive these bounds.
export const COLOMBIA_ID_MIN_DIGITS = 6;
export const COLOMBIA_ID_MAX_DIGITS = 10;

// The input's maxLength counts characters, so it has to leave room for a number pasted with
// thousands separators ("1.123.456.789"). The digit-count check below is the real bound.
export const COLOMBIA_ID_MAX_INPUT_LENGTH = 13;

// Sellers paste numbers with dots or spaces ("1.123.456"), which are cosmetic here.
const digitsOnly = (value: string) => value.replace(/\D/gu, "");

export const isValidColombiaIdNumber = (value: string) => {
  const digits = digitsOnly(value);
  return digits.length >= COLOMBIA_ID_MIN_DIGITS && digits.length <= COLOMBIA_ID_MAX_DIGITS;
};

// Named for the two documents rather than "your ID", so a foreign resident can tell the message is
// about the document they actually hold. Zero-padding a short number is called out because it is
// the workaround sellers reach for on their own, and it trades today's block for an
// id_number_match verification failure later, once they have a balance.
export const COLOMBIA_ID_NUMBER_ERROR_MESSAGE = `Your Cédula de Ciudadanía or Cédula de Extranjería must be ${COLOMBIA_ID_MIN_DIGITS}-${COLOMBIA_ID_MAX_DIGITS} digits. Enter it exactly as it appears on your document — do not add leading zeros, as the number has to match the document you may later be asked to upload.`;
