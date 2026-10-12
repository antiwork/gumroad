const DOMINICAN_REPUBLIC_CIE_PATTERN = /^\d{3}-\d{7}-\d$/u;

export const isValidDominicanRepublicCie = (value: string) => DOMINICAN_REPUBLIC_CIE_PATTERN.test(value);

export const DOMINICAN_REPUBLIC_CIE_BLANK_ERROR_MESSAGE =
  "Enter your Cédula de identidad y electoral (CIE). Stripe cannot pay out without it, and a passport is not accepted.";

export const DOMINICAN_REPUBLIC_CIE_ERROR_MESSAGE =
  "Your Cédula de identidad y electoral (CIE) must be 13 characters including the dashes (for example, 123-1234567-1). A passport number is not accepted.";
