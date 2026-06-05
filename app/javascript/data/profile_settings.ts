import typia from "typia";

import { ProfileSettings, Tab } from "$app/parsers/profile";
import { request, ResponseError } from "$app/utils/request";

import { Props as ProductProps } from "$app/components/Product";

export type Section = {
  id: string;
  header: string;
  hide_header: boolean;
};

export type ProfileSortKey = "page_layout" | "newest" | "highest_rated" | "most_reviewed" | "price_asc" | "price_desc";

export type ProductsSection = Section & {
  type: "SellerProfileProductsSection";
  shown_products: string[];
  default_product_sort: ProfileSortKey;
  show_filters: boolean;
  add_new_products: boolean;
};

export type PostsSection = Section & {
  type: "SellerProfilePostsSection";
  shown_posts: string[];
};

export type RichTextSection = Section & {
  type: "SellerProfileRichTextSection";
  text: Record<string, unknown>;
};

export type SubscribeSection = Section & {
  type: "SellerProfileSubscribeSection";
  button_label: string;
};

export type FeaturedProductSection = Section & {
  type: "SellerProfileFeaturedProductSection";
  featured_product_id?: string;
};

export type WishlistsSection = Section & {
  type: "SellerProfileWishlistsSection";
  shown_wishlists: string[];
};

export const updateProfileSettings = async (profileSettings: Partial<ProfileSettings> & { tabs?: Tab[] }) => {
  const { profile_picture_blob_id, tabs, ...user } = profileSettings;
  const response = await request({
    method: "PUT",
    url: Routes.settings_profile_path(),
    accept: "json",
    data: {
      user,
      profile_picture_blob_id,
      tabs,
    },
  });
  const json = typia.assert<{ success: false; error_message: string } | { success: true }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);
};

export const getProduct = async (id: string) => {
  const response = await request({
    method: "GET",
    url: Routes.settings_profile_product_path(id),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
  return typia.assert<ProductProps>(await response.json());
};

export const unlinkTwitter = async () => {
  const response = await request({
    method: "POST",
    url: Routes.unlink_twitter_settings_connections_path(),
    accept: "json",
  });
  const json = typia.assert<{ success: false; error_message: string } | { success: true }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);
};
