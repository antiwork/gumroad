import { FromSchema } from "json-schema-to-ts";
import { cast } from "ts-safe-cast";

import FeaturedProductSectionSchema from "$app/json_schemas/seller_profile_featured_product_section";
import PostsSectionSchema from "$app/json_schemas/seller_profile_posts_section";
import ProductsSectionSchema from "$app/json_schemas/seller_profile_products_section";
import RichTextSectionSchema from "$app/json_schemas/seller_profile_rich_text_section";
import SubscribeSectionSchema from "$app/json_schemas/seller_profile_subscribe_section";
import WishlistsSectionSchema from "$app/json_schemas/seller_profile_wishlists_section";
import { ProfileSettings, Tab } from "$app/parsers/profile";
import { request, ResponseError } from "$app/utils/request";

import { Props as ProductProps } from "$app/components/Product";

export type Section = {
  id: string;
  header: string;
  hide_header: boolean;
};

export type ProductsSection = Section & { type: "SellerProfileProductsSection"; shown_products: string[] } & Omit<
    FromSchema<typeof ProductsSectionSchema>,
    "shown_products"
  >;

export type PostsSection = Section & { type: "SellerProfilePostsSection"; shown_posts: string[] } & Omit<
    FromSchema<typeof PostsSectionSchema>,
    "shown_posts"
  >;

export type RichTextSection = Section & { type: "SellerProfileRichTextSection" } & FromSchema<
    typeof RichTextSectionSchema
  >;

export type SubscribeSection = Section & { type: "SellerProfileSubscribeSection" } & FromSchema<
    typeof SubscribeSectionSchema
  >;

export type FeaturedProductSection = Section & {
  type: "SellerProfileFeaturedProductSection";
  featured_product_id?: string;
} & Omit<FromSchema<typeof FeaturedProductSectionSchema>, "featured_product_id">;

export type WishlistsSection = Section & {
  type: "SellerProfileWishlistsSection";
  shown_wishlists: string[];
} & Omit<FromSchema<typeof WishlistsSectionSchema>, "shown_wishlists">;

export const updateProfileSettings = async (profileSettings: Partial<ProfileSettings> & { tabs?: Tab[] }) => {
  const { background_color, highlight_color, font, profile_picture_blob_id, tabs, ...user } = profileSettings;
  const response = await request({
    method: "PUT",
    url: Routes.settings_profile_path(),
    accept: "json",
    data: {
      user,
      seller_profile: { background_color, highlight_color, font },
      profile_picture_blob_id,
      tabs,
    },
  });
  const json = cast<{ success: false; error_message: string } | { success: true }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);
};

export const getProduct = async (id: string) => {
  const response = await request({
    method: "GET",
    url: Routes.settings_profile_product_path(id),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
  return cast<ProductProps>(await response.json());
};

export const unlinkTwitter = async () => {
  const response = await request({
    method: "POST",
    url: Routes.unlink_twitter_settings_connections_path(),
    accept: "json",
  });
  const json = cast<{ success: false; error_message: string } | { success: true }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);
};
