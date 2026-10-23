// Stripe's individual.id_number check for Guatemala: a body of 6-8 digits plus an optional trailing
// check letter K, or 7-9 digits, 7-9 characters in total. Server copy:
// lib/utilities/compliance/guatemala_nit.rb.
const normalize = (value: string) => value.replace(/[\s-]/gu, "").toUpperCase();

export const isValidGuatemalaNit = (value: string) => {
  const normalized = normalize(value);
  if (normalized.length < 7 || normalized.length > 9) return false;
  return /^\d{6,8}K?$/u.test(normalized) || /^\d{8,9}$/u.test(normalized);
};

export const GUATEMALA_NIT_ERROR_MESSAGE =
  "Your NIT must be 6 to 8 digits followed by a check digit or the letter K (for example, 805813-K or 1234567-4). Enter it exactly as it appears on your document.";
