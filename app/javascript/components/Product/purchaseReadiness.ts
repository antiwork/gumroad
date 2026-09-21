import type { Option, PriceSelection, Product } from "$app/components/Product/ConfigurationSelector";

export const INCOMPLETE_PURCHASE_CTA_LABEL = "Choose an option";

// Keep availability in sync with disabled option radios in ConfigurationSelector.
const isSelectable = (
  product: Pick<Product, "is_tiered_membership">,
  selection: Pick<PriceSelection, "recurrence">,
  option: Option,
): boolean =>
  option.quantity_left !== 0 &&
  !(product.is_tiered_membership && !!selection.recurrence && !option.recurrence_price_values?.[selection.recurrence]);

export const initialOptionId = (
  product: Pick<Product, "options" | "native_type">,
  searchParams: URLSearchParams,
): string | null => {
  const requested = product.options.find(
    (option: Option) => option.id === searchParams.get("option") || option.name === searchParams.get("variant"),
  );
  if (requested && requested.quantity_left !== 0) return requested.id;
  // Coffee defaults to the first available preset; a blank option represents "Other".
  if (product.options.length <= 1 || product.native_type === "coffee") {
    return product.options.find((option: Option) => option.quantity_left !== 0)?.id ?? null;
  }
  return null;
};

// Only request a choice when an option is available. Coffee's blank option means "Other".
export const needsOptionChoice = (
  product: Pick<Product, "options" | "native_type" | "is_tiered_membership">,
  selection: Pick<PriceSelection, "optionId" | "recurrence">,
): boolean =>
  product.native_type !== "coffee" &&
  product.options.length > 1 &&
  !selection.optionId &&
  product.options.some((option: Option) => isSelectable(product, selection, option));

export const isSelectionComplete = (product: Product, selection: PriceSelection): boolean => {
  if (needsOptionChoice(product, selection)) return false;
  const selectedOption = product.options.find((option: Option) => option.id === selection.optionId);
  const isPWYW = product.is_tiered_membership ? (selectedOption?.is_pwyw ?? false) : !!product.pwyw;
  if (isPWYW && selection.price.value === null) return false;
  if (product.native_type === "call" && !selection.callStartTime) return false;
  return true;
};
