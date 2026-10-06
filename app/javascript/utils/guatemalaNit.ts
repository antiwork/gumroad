// Stripe's individual.id_number check for Guatemala: 7-8 digits plus an optional trailing check
// letter K, 8-9 characters in total. Server copy: lib/utilities/compliance/guatemala_nit.rb.
const normalize = (value: string) => value.replace(/[\s-]/gu, "").toUpperCase();

export const isValidGuatemalaNit = (value: string) => {
  const normalized = normalize(value);
  if (normalized.length < 8 || normalized.length > 9) return false;
  return /^\d{7,8}K?$/u.test(normalized) || /^\d{8,9}$/u.test(normalized);
};

export const GUATEMALA_NIT_ERROR_MESSAGE =
  "Your NIT must be 7 or 8 digits followed by a check digit or the letter K (for example, 1234567-8 or 1234567-K). Enter it exactly as it appears on your document.";
