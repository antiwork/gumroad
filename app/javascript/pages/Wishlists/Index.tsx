import { router, useForm, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Toggle } from "$app/components/Toggle";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/wishlists.png";

export type Wishlist = {
  id: string;
  name: string;
  url: string;
  product_count: number;
  discover_opted_out: boolean;
};

type Props = {
  wishlists: Wishlist[];
  reviews_page_enabled: boolean;
  following_wishlists_enabled: boolean;
};

export default function WishlistsPage() {
  const { wishlists, reviews_page_enabled, following_wishlists_enabled } = cast<Props>(usePage().props);
  const [deletingWishlist, setConfirmingDeleteWishlist] = React.useState<Wishlist | null>(null);

  const deleteForm = useForm({});
  const destroy = (id: string) => {
    deleteForm.delete(Routes.wishlist_path(id), {
      preserveScroll: true,
      onSuccess: () => setConfirmingDeleteWishlist(null),
      onError: () => showAlert("Sorry, something went wrong. Please try again.", "error"),
    });
  };

  const updateDiscoverOptOut = (id: string, optOut: boolean) => {
    router.put(
      Routes.wishlist_path(id),
      { wishlist: { discover_opted_out: optOut } },
      {
        preserveScroll: true,
        onError: () => showAlert("Sorry, something went wrong. Please try again.", "error"),
      },
    );
  };

  return (
    <Layout
      selectedTab="wishlists"
      reviewsPageEnabled={reviews_page_enabled}
      followingWishlistsEnabled={following_wishlists_enabled}
    >
      <section className="space-y-4 p-4 md:p-8">
        {wishlists.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Wishlist</TableHead>
                <TableHead>Products</TableHead>
                <TableHead>
                  Discoverable&nbsp;
                  <WithTooltip
                    tip={
                      <span className="font-normal" style={{ textWrap: "initial" }}>
                        May be recommended on Gumroad Discover. You will receive an affiliate commission for any sales.
                      </span>
                    }
                    position="top"
                  >
                    <Icon name="info-circle" />
                  </WithTooltip>
                </TableHead>
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
                    <Toggle
                      value={!wishlist.discover_opted_out}
                      onChange={(checked) => updateDiscoverOptOut(wishlist.id, !checked)}
                      ariaLabel="Discoverable"
                    />
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-3 lg:justify-end">
                      <Button
                        color="danger"
                        outline
                        aria-label="Delete wishlist"
                        onClick={() => setConfirmingDeleteWishlist(wishlist)}
                      >
                        <Icon name="trash2" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>Save products you are wishing for</h2>
            Bookmark and organize your desired products with ease
            <a href="/help/article/343-wishlists" target="_blank" rel="noreferrer">
              Learn more about wishlists
            </a>
          </Placeholder>
        )}

        {deletingWishlist ? (
          <Modal
            open
            onClose={() => setConfirmingDeleteWishlist(null)}
            title="Delete wishlist?"
            footer={
              <>
                <Button onClick={() => setConfirmingDeleteWishlist(null)}>No, cancel</Button>
                <Button color="danger" disabled={deleteForm.processing} onClick={() => destroy(deletingWishlist.id)}>
                  {deleteForm.processing ? "Deleting..." : "Yes, delete"}
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
}
