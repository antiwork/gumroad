// NOTE: keep in sync with lib/utilities/card_type.rb
export type CreditCardType =
  | "discover"
  | "generic_card"
  | "visa"
  | "amex"
  | "mastercard"
  | "jcb"
  | "diners"
  | "unionpay"
  | "upi";

export type SavedCreditCard = {
  type: CreditCardType;
  number: string;
  expiration_date: string | null;
  requires_mandate: boolean;
};
