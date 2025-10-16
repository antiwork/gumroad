import * as React from "react";
import { createCast } from "ts-safe-cast";

import { unfollowWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import Placeholder from "$app/components/ui/Placeholder";

import placeholder from "$assets/images/placeholders/wishlists-following.png";

type Wishlist = {
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

const WishlistsFollowingPage = ({
  wishlists: preloadedWishlists,
  reviews_page_enabled,
}: {
  wishlists: Wishlist[];
  reviews_page_enabled: boolean;
}) => {
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
          <table>
            <thead>
              <tr>
                <th>Wishlist</th>
                <th>Products</th>
                <th>Creator</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {wishlists.map((wishlist) => (
                <tr key={wishlist.id}>
                  <td>
                    <a href={wishlist.url} target="_blank" rel="noreferrer" style={{ textDecoration: "none" }}>
                      <h4>{wishlist.name}</h4>
                    </a>
                    <a href={wishlist.url} target="_blank" rel="noreferrer">
                      <small>{wishlist.url}</small>
                    </a>
                  </td>
                  <td>{wishlist.product_count}</td>
                  <td>
                    <a
                      href={wishlist.creator.profile_url}
                      style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}
                    >
                      <img className="user-avatar" src={wishlist.creator.avatar_url} />
                      <span>{wishlist.creator.name}</span>
                    </a>
                  </td>
                  <td>
                    <div className="actions">
                      <Popover aria-label="Actions" trigger={<Icon name="three-dots" />}>
                        <div role="menu">
                          <div role="menuitem" className="danger" onClick={() => void destroy(wishlist)}>
                            <Icon name="bookmark-x" /> Unfollow
                          </div>
                        </div>
                      </Popover>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <Placeholder>
            <figure>
              <img src={placeholder} />
            </figure>
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
};

export default register({ component: WishlistsFollowingPage, propParser: createCast() });
