import { CardProduct } from "$app/parsers/product";

export type BundleProduct = CardProduct & {
  is_quantity_enabled: boolean;
  quantity: number;
  created_at: string;
  variants: {
    selected_id: string;
    list: {
      id: string;
      name: string;
      description: string;
      price_difference: number;
    }[];
  } | null;
};
