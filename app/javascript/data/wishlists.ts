import { cast } from "ts-safe-cast";

import { ResponseError, request } from "$app/utils/request";

import { WishlistItem } from "$app/components/Wishlist";
import { CardWishlist } from "$app/components/Wishlist/Card";

export type Wishlist = {
  id: string;
  name: string;
};

export const createWishlist = async () => {
  const response = await request({
    method: "POST",
    url: Routes.wishlists_path(),
    accept: "json",
  });
  return cast<{ wishlist: Wishlist }>(await response.json());
};

type FetchPaginatedWishlistItemsArgs = {
  wishlist_id: string;
  page: number | null;
};

type PaginatedWishlistItems = {
  items: WishlistItem[];
  pagination: {
    count: number;
    items: number;
    page: number;
    pages: number;
    prev: number | null;
    next: number | null;
    last: number;
  };
};

export const fetchPaginatedWishlistItems = async ({
  wishlist_id,
  page,
}: FetchPaginatedWishlistItemsArgs): Promise<PaginatedWishlistItems> => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.wishlist_products_path(wishlist_id, { page }),
  });
  if (!response.ok) throw new ResponseError();
  return cast<PaginatedWishlistItems>(await response.json());
};

export const addToWishlist = async ({
  wishlistId,
  productId,
  optionId,
  recurrence,
  rent,
  quantity,
}: {
  wishlistId: string;
  productId: string;
  optionId: string | null;
  recurrence: string | null;
  rent: boolean;
  quantity: number | null;
}) => {
  const response = await request({
    method: "POST",
    url: Routes.wishlist_products_path(wishlistId),
    accept: "json",
    data: {
      wishlist_product: {
        product_id: productId,
        option_id: optionId,
        recurrence,
        rent,
        quantity,
      },
    },
  });
  if (!response.ok) {
    const data = cast<{ error: string }>(await response.json());
    throw new ResponseError(data.error);
  }
};

export const updateWishlist = async ({
  id,
  ...wishlist
}: {
  id: string;
  name?: string;
  description?: string | null;
  discover_opted_out?: boolean;
}) => {
  const response = await request({
    method: "PUT",
    url: Routes.wishlist_path(id),
    accept: "json",
    data: { wishlist },
  });
  if (!response.ok) {
    const data = cast<{ error: string }>(await response.json());
    throw new ResponseError(data.error);
  }
};

export const deleteWishlist = async ({ wishlistId }: { wishlistId: string }) => {
  const response = await request({
    method: "DELETE",
    url: Routes.wishlist_path(wishlistId),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
};

export const deleteWishlistItem = async ({
  wishlistId,
  wishlistProductId,
}: {
  wishlistId: string;
  wishlistProductId: string;
}) => {
  const response = await request({
    method: "DELETE",
    url: Routes.wishlist_product_path(wishlistId, wishlistProductId),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
};

export const followWishlist = async ({ wishlistId }: { wishlistId: string }) => {
  const response = await request({
    method: "POST",
    url: Routes.wishlist_followers_path(wishlistId),
    accept: "json",
  });
  if (!response.ok) {
    const data = cast<{ error: string }>(await response.json());
    throw new ResponseError(data.error);
  }
};

export const unfollowWishlist = async ({ wishlistId }: { wishlistId: string }) => {
  const response = await request({
    method: "DELETE",
    url: Routes.wishlist_followers_path(wishlistId),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
};

export const fetchWishlists = async (ids: string[]) => {
  const response = await request({
    method: "GET",
    url: Routes.wishlists_path({ ids }),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
  return cast<CardWishlist[]>(await response.json());
};

export const fetchRecommendedWishlists = async ({
  curatedProductIds,
  taxonomy,
}: {
  curatedProductIds?: string[];
  taxonomy?: string | null;
}) => {
  const response = await request({
    method: "GET",
    url: Routes.discover_recommended_wishlists_path({ curated_product_ids: curatedProductIds, taxonomy }),
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
  return cast<CardWishlist[]>(await response.json());
};
