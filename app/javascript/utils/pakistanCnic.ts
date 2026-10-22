// Keep in step with lib/utilities/compliance/pakistan_cnic.rb, including the message.
export const PAKISTAN_CNIC_DIGITS = 13;

// 13 digits, or the 5-7-1 grouping printed on the card. Whitespace from a paste is ignored.
const PAKISTAN_CNIC_PATTERN = /^(?:\d{13}|\d{5}-\d{7}-\d)$/u;
// \s plus U+0085, the same set as the server's [[:space:]\uFEFF].
const PAKISTAN_CNIC_WHITESPACE = /[\s\u0085]/gu;

export const isValidPakistanCnic = (value: string) =>
  PAKISTAN_CNIC_PATTERN.test(value.replace(PAKISTAN_CNIC_WHITESPACE, ""));

export const PAKISTAN_CNIC_HELP_TEXT = `${PAKISTAN_CNIC_DIGITS} digits, dashes optional`;

export const PAKISTAN_CNIC_ERROR_MESSAGE = `Your CNIC must be ${PAKISTAN_CNIC_DIGITS} digits (for example, 12345-1234567-1). Enter it exactly as it appears on your card — the dashes are optional.`;
