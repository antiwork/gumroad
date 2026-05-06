export type ProductOption = {
  name: string;
  native_type: "digital" | "course" | "ebook" | "membership";
  price_cents: number;
  description: string;
  rationale_one_line: string;
  is_primary: boolean;
};

export type OptionsResponse = {
  options: ProductOption[];
  source?: "ai" | "templates";
  capped?: boolean;
};
