// Keep in step with lib/utilities/compliance/uae_emirates_id.rb, including the message.
export const UAE_EMIRATES_ID_DIGITS = 15;

// 15 digits, or the 3-4-7-1 grouping printed on the card. Whitespace from a paste is ignored.
const UAE_EMIRATES_ID_PATTERN = /^(?:\d{15}|\d{3}-\d{4}-\d{7}-\d)$/u;
// \s plus U+0085, the same set as the server's [[:space:]\uFEFF].
const UAE_EMIRATES_ID_WHITESPACE = /[\s\u0085]/gu;

export const isValidUaeEmiratesId = (value: string) =>
  UAE_EMIRATES_ID_PATTERN.test(value.replace(UAE_EMIRATES_ID_WHITESPACE, ""));

export const UAE_EMIRATES_ID_HELP_TEXT = `${UAE_EMIRATES_ID_DIGITS} digits, dashes optional`;

export const UAE_EMIRATES_ID_ERROR_MESSAGE = `Your Emirates ID must be ${UAE_EMIRATES_ID_DIGITS} digits (for example, 784-1234-1234567-1). Enter it exactly as it appears on your card — the dashes are optional.`;
