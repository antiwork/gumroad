// Keep in step with lib/utilities/compliance/pakistan_cnic.rb, including the message.
export const PAKISTAN_CNIC_DIGITS = 13;

// maxLength counts characters, so leave room for the two dashes.
export const PAKISTAN_CNIC_MAX_INPUT_LENGTH = PAKISTAN_CNIC_DIGITS + 2;

// Sellers paste the number as printed; the dashes are cosmetic here.
const digitsOnly = (value: string) => value.replace(/\D/gu, "");

export const isValidPakistanCnic = (value: string) => digitsOnly(value).length === PAKISTAN_CNIC_DIGITS;

export const PAKISTAN_CNIC_HELP_TEXT = `${PAKISTAN_CNIC_DIGITS} digits, dashes optional`;

export const PAKISTAN_CNIC_ERROR_MESSAGE = `Your CNIC must be ${PAKISTAN_CNIC_DIGITS} digits (for example, 12345-1234567-1). Enter it exactly as it appears on your card — the dashes are optional.`;
