// A Pakistani CNIC is 13 digits, printed 5-7-1 with dashes ("42101-1234567-1"). Stripe takes the
// digits only in individual.id_number, and the server strips the dashes before sending — see
// lib/utilities/compliance/pakistan_cnic.rb. Changing these constants also means editing that
// module and the message it returns.
export const PAKISTAN_CNIC_DIGITS = 13;

// The input's maxLength counts characters, so it has to leave room for the two dashes the card is
// printed with: a cap of 13 silently truncates a pasted "42101-1234567-1" mid-number, which is how
// a seller ends up sending Stripe a value with the last digit missing. The digit count below is
// the real bound.
export const PAKISTAN_CNIC_MAX_INPUT_LENGTH = PAKISTAN_CNIC_DIGITS + 2;

// Sellers paste the number as printed; the dashes are cosmetic here.
const digitsOnly = (value: string) => value.replace(/\D/gu, "");

export const isValidPakistanCnic = (value: string) => digitsOnly(value).length === PAKISTAN_CNIC_DIGITS;

export const PAKISTAN_CNIC_ERROR_MESSAGE = `Your CNIC must be ${PAKISTAN_CNIC_DIGITS} digits (for example, 12345-1234567-1). Enter it exactly as it appears on your card — the dashes are optional.`;
