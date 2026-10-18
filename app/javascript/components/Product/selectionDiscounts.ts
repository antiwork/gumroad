import * as React from "react";

import { getSelectionDiscounts } from "$app/data/offer_code";
import type { RecurrenceId } from "$app/utils/recurringPricing";
import { AbortError, ResponseError } from "$app/utils/request";

import { applySelection, type PriceSelection, type Product } from "$app/components/Product/ConfigurationSelector";
import type { ProductDiscount } from "$app/components/Product/index";

type OptionQuotes = Record<string, { discount_code: ProductDiscount | null; sale_label: string | null }>;

// The server's pick for each option, keyed by option id ("" for a product without options), and the
// selection inputs it was quoted for. rent_options holds the rental's picks when the buyer can also buy.
export type SelectionDiscounts = {
  url_code: string | null;
  quantity: number;
  recurrence: RecurrenceId | null;
  option_id: string | null;
  price_cents: number | null;
  options: OptionQuotes;
  rent_options: OptionQuotes | null;
};

type Inputs = Pick<SelectionDiscounts, "quantity" | "recurrence" | "option_id" | "price_cents">;

// "incomplete" is a selection the server cannot quote yet, such as a cleared quantity: nothing is asked
// and the buy buttons wait quietly until the buyer finishes it.
export type SelectionQuote = { state: "ready" | "loading" | "failed" | "incomplete"; retry: () => void };

const PWYW_QUOTE_DELAY_MS = 300;

const selectionInputs = (product: Product, selection: PriceSelection): Inputs => {
  const pwyw = applySelection(product, null, selection).isPWYW && selection.price.value !== null;
  return {
    quantity: selection.quantity,
    recurrence: selection.recurrence,
    option_id: pwyw ? selection.optionId : null,
    price_cents: pwyw ? selection.price.value : null,
  };
};
const inputsKey = (inputs: Inputs) =>
  JSON.stringify([inputs.quantity, inputs.recurrence, inputs.option_id, inputs.price_cents]);
const answersFor = (initial: SelectionDiscounts | null | undefined) =>
  initial ? { [inputsKey(initial)]: initial } : {};

// Re-asks the server whenever the inputs that change its pick do. Answers are kept by the inputs they
// were quoted for, and a selection only ever uses its own: until it lands, or if it fails, no code is
// shown for it and the quote is not ready.
export const useSelectionDiscounts = ({
  product,
  discountCode,
  saleLabel,
  initial,
  selection,
}: {
  product: Product;
  discountCode: ProductDiscount | null;
  saleLabel: string | null;
  initial: SelectionDiscounts | null | undefined;
  selection: PriceSelection;
}) => {
  const [answers, setAnswers] = React.useState<Record<string, SelectionDiscounts>>(() => answersFor(initial));
  // New page props start over; on mount the state already holds them.
  React.useEffect(
    () => setAnswers((current) => (initial && current[inputsKey(initial)] === initial ? current : answersFor(initial))),
    [initial],
  );
  const [failedKey, setFailedKey] = React.useState<string | null>(null);
  const [attempt, setAttempt] = React.useState(0);

  // No answer has options when there is no code to weigh, so nothing needs asking.
  const quotable = !!initial && Object.keys(initial.options).length > 0;
  const inputs = selectionInputs(product, selection);
  const key = inputsKey(inputs);
  const answer = answers[key];
  const missing = quotable && !answer;
  const incomplete = !Number.isInteger(inputs.quantity) || inputs.quantity < 1;
  React.useEffect(() => {
    if (!missing || incomplete) return;
    let request: ReturnType<typeof getSelectionDiscounts> | null = null;
    const timeout = setTimeout(
      () => {
        setFailedKey(null);
        request = getSelectionDiscounts({ permalink: product.permalink, code: initial.url_code, ...inputs });
        request.response
          .then((quote) => {
            if (inputsKey(quote) !== key) throw new ResponseError();
            setAnswers((current) => ({ ...current, [key]: quote }));
          })
          .catch((error: unknown) => {
            if (!(error instanceof AbortError)) setFailedKey(key);
          });
      },
      inputs.price_cents === null ? 0 : PWYW_QUOTE_DELAY_MS,
    );
    return () => {
      clearTimeout(timeout);
      request?.cancel();
    };
  }, [key, missing, incomplete, attempt]);

  const quote: SelectionQuote = {
    state: !missing ? "ready" : incomplete ? "incomplete" : failedKey === key ? "failed" : "loading",
    retry: () => setAttempt((count) => count + 1),
  };
  if (!quotable) return { discountCode, saleLabel, selectionDiscountCode: undefined, quote };

  const entry = (optionId: string | null, rent: boolean) =>
    (rent && answer?.rent_options ? answer.rent_options : answer?.options)?.[optionId ?? ""];
  // With options but none picked, the page shows the code quoted with the page, for the inputs it had.
  const unpicked = product.options.length > 0 && selection.optionId === null;
  const initialInputs = key === inputsKey(initial);
  const selected = unpicked ? null : entry(selection.optionId, selection.rent);
  return {
    discountCode: unpicked ? (initialInputs ? discountCode : null) : (selected?.discount_code ?? null),
    saleLabel: unpicked ? (initialInputs ? saleLabel : null) : (selected?.sale_label ?? null),
    selectionDiscountCode: (optionId: string | null, rent: boolean) => entry(optionId, rent)?.discount_code ?? null,
    quote,
  };
};
