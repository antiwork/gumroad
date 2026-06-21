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

export type ProfileSection =
  | ProductsSection
  | PostsSection
  | RichTextSection
  | SubscribeSection
  | FeaturedProductSection
  | WishlistsSection;

export const updateProfileSettings = async (
  profileSettings: Partial<ProfileSettings> & {
    tabs?: Tab[];
    sections?: ProfileSection[];
    profileVersion?: string | null;
  },
) => {
  const { profile_picture_blob_id, tabs, sections, profileVersion, ...user } = profileSettings;
  const response = await request({
    method: "PUT",
    url: Routes.profile_path(),
    accept: "json",
    data: {
      user,
      profile_picture_blob_id,
      // Omit pages/sections entirely when the caller didn't pass them, so a settings-only save
      // doesn't replace (and prune) the server's section list. When they are sent, profile_version
      // lets the server reject the write if the layout changed elsewhere since this editor loaded.
      ...(tabs !== undefined ? { tabs } : {}),
      ...(sections !== undefined ? { sections } : {}),
      ...(profileVersion !== undefined ? { profile_version: profileVersion } : {}),
    },
  });
  const json = typia.assert<{ success: false; error_message: string } | { success: true }>(await response.json());
  if (!json.success) throw new ResponseError(json.error_message);
};

export const getProduct = async (id: string) => {
  const response = await request({
    method: "GET",
    url: Routes.profile_product_path(id),
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
