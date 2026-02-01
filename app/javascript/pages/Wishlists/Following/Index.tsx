import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { unfollowWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

import placeholder from "$assets/images/placeholders/wishlists-following.png";

export type Wishlist = {
  id: string;
  name: string;
  url: string;
  creator: {
    name: string;
    profile_url: string;
    avatar_url: string;
  };
  product_count: number;
};

type Props = {
  wishlists: Wishlist[];
  reviews_page_enabled: boolean;
};

export default function WishlistsFollowingPage() {
  const { wishlists: preloadedWishlists, reviews_page_enabled } = cast<Props>(usePage().props);

  const [wishlists, setWishlists] = React.useState<Wishlist[]>(preloadedWishlists);

  const destroy = async (wishlist: Wishlist) => {
    setWishlists(wishlists.filter(({ id }) => id !== wishlist.id));
    try {
      await unfollowWishlist({ wishlistId: wishlist.id });
      showAlert(`You are no longer following ${wishlist.name}.`, "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  return (
    <Layout selectedTab="following_wishlists" reviewsPageEnabled={reviews_page_enabled} followingWishlistsEnabled>
      <section className="p-4 md:p-8">
        {wishlists.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Wishlist</TableHead>
                <TableHead>Products</TableHead>
                <TableHead>Creator</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {wishlists.map((wishlist) => (
                <TableRow key={wishlist.id}>
                  <TableCell>
                    <a href={wishlist.url} target="_blank" rel="noreferrer" style={{ textDecoration: "none" }}>
                      <h4>{wishlist.name}</h4>
                    </a>
                    <a href={wishlist.url} target="_blank" rel="noreferrer">
                      <small>{wishlist.url}</small>
                    </a>
                  </TableCell>
                  <TableCell>{wishlist.product_count}</TableCell>
                  <TableCell>
                    <a
                      href={wishlist.creator.profile_url}
                      style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}
                    >
                      <img className="user-avatar" src={wishlist.creator.avatar_url} />
                      <span>{wishlist.creator.name}</span>
                    </a>
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-3 lg:justify-end">
                      <Popover>
                        <PopoverTrigger aria-label="Actions">
                          <Icon name="three-dots" />
                        </PopoverTrigger>
                        <PopoverContent className="border-0 p-0 shadow-none">
                          <div role="menu">
                            <div role="menuitem" className="danger" onClick={() => void destroy(wishlist)}>
                              <Icon name="bookmark-x" /> Unfollow
                            </div>
                          </div>
                        </PopoverContent>
                      </Popover>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>Follow wishlists that inspire you</h2>
            Bookmark and organize your desired products with ease
            <a href="/help/article/343-wishlists" target="_blank" rel="noreferrer">
              Learn more about wishlists
            </a>
          </Placeholder>
        )}
      </section>
    </Layout>
  );
}
