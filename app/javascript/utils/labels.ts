import { ProductNativeType } from "$app/parsers/product";

const NATIVE_TYPE_TO_VARIANT_LABEL: Partial<Record<ProductNativeType, string>> = {
  call: "Duration",
  coffee: "Amount",
  membership: "Tier",
  physical: "Variant",
};

export const variantLabel = (type: ProductNativeType): string => NATIVE_TYPE_TO_VARIANT_LABEL[type] || "Version";
