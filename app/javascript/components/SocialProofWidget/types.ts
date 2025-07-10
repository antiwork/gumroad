export interface SocialProofWidgetData {
  id: string;
  name: string;
  title: string;
  description: string;
  cta_text: string;
  cta_type: "button" | "link" | "none";
  image_url?: string | null;
  image_type: string;
  icon_name?: string | null;
  icon_color: string | null;
  status?: "published" | "unpublished";
}

export type WidgetFormData = {
  id?: string;
  name: string;
  universal: boolean;
  title: string;
  description: string;
  cta_text: string;
  cta_type: "button" | "link" | "none";
  image_type: string;
  custom_image_url?: string | null;
  product_ids: string[];
  available_products: ProductOption[];
  image_type_options: ImageTypeOption[];
  cta_type_options: CtaTypeOption[];
  icon_options: IconOption[];
}

export type ProductOption = {
  id: string;
  name: string;
  thumbnail_url?: string | null;
}

export type ImageTypeOption = {
  value: string;
  label: string;
}

export type CtaTypeOption = {
  value: string;
  label: string;
}

export type IconOption = {
  value: string;
  label: string;
}