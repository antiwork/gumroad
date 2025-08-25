import * as React from "react";
import { createCast } from "ts-safe-cast";

import { deleteWishlist, updateWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Toggle } from "$app/components/Toggle";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/wishlists.png";

type Wishlist = {
  id: string;
  name: string;
  url: string;
  product_count: number;
  discover_opted_out: boolean;
};

const WishlistsPage = ({
  wishlists: preloadedWishlists,
  reviews_page_enabled,
  following_wishlists_enabled,
}: {
  wishlists: Wishlist[];
  reviews_page_enabled: boolean;
  following_wishlists_enabled: boolean;
}) => {
  const [wishlists, setWishlists] = React.useState<Wishlist[]>(preloadedWishlists);
  const [deletingWishlist, setConfirmingDeleteWishlist] = React.useState<Wishlist | null>(null);
  const [isDeleting, setIsDeleting] = React.useState(false);

  const destroy = async (id: string) => {
    setIsDeleting(true);

    try {
      await deleteWishlist({ wishlistId: id });
      setWishlists(wishlists.filter((wishlist) => wishlist.id !== id));
      setConfirmingDeleteWishlist(null);
      showAlert("Wishlist deleted!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setIsDeleting(false);
    }
  };

  const updateDiscoverOptOut = async (id: string, optOut: boolean) => {
    try {
      setWishlists(
        wishlists.map((wishlist) => (wishlist.id === id ? { ...wishlist, discover_opted_out: optOut } : wishlist)),
      );
      await updateWishlist({ id, discover_opted_out: optOut });
      showAlert(optOut ? "Opted out of Gumroad Discover." : "Wishlist is now discoverable!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  return (
    <Layout
      selectedTab="wishlists"
      reviewsPageEnabled={reviews_page_enabled}
      followingWishlistsEnabled={following_wishlists_enabled}
    >
      <section>
        {wishlists.length > 0 ? (
          <table>
            <thead>
              <tr>
                <th>Wishlist</th>
                <th>Products</th>
                <th>
                  Discoverable&nbsp;
                  <WithTooltip
                    tip={
                      <span style={{ fontWeight: "normal", textWrap: "initial" }}>
                        May be recommended on Gumroad Discover. You will receive an affiliate commission for any sales.
                      </span>
                    }
                    position="top"
                  >
                    <Icon name="info-circle" />
                  </WithTooltip>
                </th>
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
                  <td data-label="Products">{wishlist.product_count}</td>
                  <td data-label="Discoverable">
                    <Toggle
                      value={!wishlist.discover_opted_out}
                      onChange={(checked) => void updateDiscoverOptOut(wishlist.id, !checked)}
                      ariaLabel="Discoverable"
                    />
                  </td>
                  <td>
                    <div className="actions">
                      <Button color="danger" outline aria-label="Delete wishlist" onClick={() => setConfirmingDeleteWishlist(wishlist)}>
                        <Icon name="trash2" />
                      </Button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Save products you are wishing for</h2>
            Bookmark and organize your desired products with ease
            <a href="/help/article/343-wishlists" target="_blank" rel="noreferrer">
              Learn more about wishlists
            </a>
          </div>
        )}

        {deletingWishlist ? (
          <Modal
            open
            onClose={() => setConfirmingDeleteWishlist(null)}
            title="Delete wishlist?"
            footer={
              <>
                <Button onClick={() => setConfirmingDeleteWishlist(null)}>No, cancel</Button>
                <Button color="danger" disabled={isDeleting} onClick={() => void destroy(deletingWishlist.id)}>
                  {isDeleting ? "Deleting..." : "Yes, delete"}
                </Button>
              </>
            }
          >
            <h4>
              Are you sure you want to delete the wishlist "{deletingWishlist.name}"? This action cannot be undone.
            </h4>
          </Modal>
        ) : null}
      </section>
    </Layout>
  );
};

export default register({ component: WishlistsPage, propParser: createCast() });
