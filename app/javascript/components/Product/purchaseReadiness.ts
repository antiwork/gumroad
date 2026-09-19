import type { Option, PriceSelection, Product } from "$app/components/Product/ConfigurationSelector";

export const INCOMPLETE_PURCHASE_CTA_LABEL = "Choose an option";

export const initialOptionId = (product: Pick<Product, "options">, searchParams: URLSearchParams): string | null => {
  const requested = product.options.find(
    (option: Option) => option.id === searchParams.get("option") || option.name === searchParams.get("variant"),
  );
  if (requested && requested.quantity_left !== 0) return requested.id;
  if (product.options.length <= 1) {
    return product.options.find((option: Option) => option.quantity_left !== 0)?.id ?? null;
  }
  return null;
};

/**
 * Whether the buyer still has to pick a SKU before the CTA can mean anything — the only state
 * that relabels the button. Coffee pages already show their "Other" tab as chosen, and a missing
 * PWYW amount or call time keeps its own label and inline prompt, so neither belongs here.
 */
export const needsOptionChoice = (
  product: Pick<Product, "options" | "native_type">,
  selection: Pick<PriceSelection, "optionId">,
): boolean => product.options.length > 1 && !selection.optionId && product.native_type !== "coffee";

export const isSelectionComplete = (product: Product, selection: PriceSelection): boolean => {
  if (product.options.length > 1 && !selection.optionId) return false;
  const selectedOption = product.options.find((option: Option) => option.id === selection.optionId);
  const isPWYW = product.is_tiered_membership ? (selectedOption?.is_pwyw ?? false) : !!product.pwyw;
  if (isPWYW && selection.price.value === null) return false;
  if (product.native_type === "call" && !selection.callStartTime) return false;
  return true;
};
