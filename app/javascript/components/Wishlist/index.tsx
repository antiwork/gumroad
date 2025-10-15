import uniqBy from "lodash/uniqBy";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { fetchPaginatedWishlistItems, deleteWishlistItem } from "$app/data/wishlists";
import { CardProduct } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { RecurrenceId, recurrenceNames } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Card } from "$app/components/Product/Card";
import { Option } from "$app/components/Product/ConfigurationSelector";
import { trackCtaClick } from "$app/components/Product/CtaButton";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { FollowButton } from "$app/components/Wishlist/FollowButton";
import { WishlistEditor } from "$app/components/Wishlist/WishlistEditor";
import { WithTooltip } from "$app/components/WithTooltip";

export type WishlistItem = {
  id: string;
  product: CardProduct;
  option: Option | null;
  recurrence: RecurrenceId | null;
  quantity: number;
  rent: boolean;
  purchasable: boolean;
  giftable: boolean;
  created_at: string;
};

export type WishlistProps = {
  id: string;
  name: string;
  description: string | null;
  url: string;
  user: {
    name: string;
    profile_url: string;
    avatar_url: string;
  } | null;
  following: boolean;
  can_follow: boolean;
  can_edit: boolean;
  discover_opted_out: boolean | null;
  checkout_enabled: boolean;
  items: WishlistItem[];
  isDiscover?: boolean;
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

const formatName = ({ product, option, recurrence }: WishlistItem) => {
  const parts = [product.name];
  if (option && option.name !== product.name) {
    parts.push(option.name);
  }
  if (recurrence) {
    parts.push(recurrenceNames[recurrence]);
  }
  return parts.join(" - ");
};

const addToCartUrl = (item: WishlistItem) => {
  const url = new URL(item.product.url);
  url.searchParams.set("wanted", "true");
  if (item.option) url.searchParams.set("option", item.option.id);
  if (item.recurrence) url.searchParams.set("recurrence", item.recurrence);
  if (item.rent) url.searchParams.set("rent", "true");
  if (item.quantity > 1) url.searchParams.set("quantity", item.quantity.toString());
  return url.toString();
};

const WishlistItemCard = ({
  wishlistId,
  item,
  onDelete,
  canEdit,
}: {
  wishlistId: string;
  item: WishlistItem;
  onDelete: () => void;
  canEdit: boolean;
}) => {
  const [isDeleting, setIsDeleting] = React.useState(false);

  const destroy = async () => {
    setIsDeleting(true);

    try {
      await deleteWishlistItem({ wishlistId, wishlistProductId: item.id });
      showAlert("Removed from wishlist", "success");
      onDelete();
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <Card
      key={item.id}
      product={{ ...item.product, name: formatName(item) }}
      footerAction={
        <>
          {canEdit ? (
            <div style={{ padding: 0, display: "grid" }}>
              <WithTooltip position="top" tip="Remove this product">
                <button
                  disabled={isDeleting}
                  aria-label="Remove this product"
                  onClick={() => void destroy()}
                  className="grid p-4"
                >
                  <Icon name="trash2" />
                </button>
              </WithTooltip>
            </div>
          ) : null}
          {item.purchasable && item.giftable ? (
            <div style={{ padding: 0, display: "grid" }}>
              <WithTooltip position="top" tip="Gift this product">
                <a
                  aria-label="Gift this product"
                  href={Routes.checkout_index_url({ params: { gift_wishlist_product: item.id } })}
                  className="grid p-4"
                >
                  <Icon name="gift-fill" />
                </a>
              </WithTooltip>
            </div>
          ) : null}
        </>
      }
      badge={
        item.purchasable ? (
          <div style={{ position: "absolute", top: "var(--spacer-4)", right: "var(--spacer-4)" }}>
            <WithTooltip position="top" tip="Add to cart">
              <NavigationButton
                href={addToCartUrl(item)}
                color="primary"
                aria-label="Add to cart"
                onClick={() =>
                  trackCtaClick({
                    sellerId: item.product.seller?.id,
                    permalink: item.product.permalink,
                    name: item.product.name,
                  })
                }
              >
                <Icon name="cart3-fill" />
              </NavigationButton>
            </WithTooltip>
          </div>
        ) : null
      }
    />
  );
};

export const Wishlist = ({
  id,
  name: initialName,
  description: initialDescription,
  url,
  user,
  following,
  can_follow,
  can_edit,
  discover_opted_out,
  checkout_enabled,
  items: initialItems,
  isDiscover,
  pagination: initialPagination,
}: WishlistProps) => {
  const [name, setName] = React.useState(initialName);
  const [description, setDescription] = React.useState(initialDescription);
  const [items, setItems] = React.useState(initialItems);
  const [pagination, setPagination] = React.useState(initialPagination);
  const [isEditing, setIsEditing] = React.useState(false);
  const [loadingMore, setLoadingMore] = React.useState(false);
  const gridRef = React.useRef<HTMLDivElement | null>(null);

  const loadMoreWishlistItems = async () => {
    if (loadingMore) return;

    setLoadingMore(true);
    try {
      const loaded = await fetchPaginatedWishlistItems({
        wishlist_id: id,
        page: pagination.next,
      });
      setItems((prev) => uniqBy([...prev, ...loaded.items], "id"));
      setPagination(loaded.pagination);
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred while loading more items", "error");
    }
    setLoadingMore(false);
  };

  React.useEffect(() => {
    const observer = new IntersectionObserver((e) => {
      if (e[0]?.isIntersecting && !loadingMore && pagination.next) void loadMoreWishlistItems();
    });

    if (items.length && gridRef.current?.lastElementChild) observer.observe(gridRef.current.lastElementChild);

    return () => observer.disconnect();
  }, [pagination, items]);

  return (
    <>
      <PageHeader
        className={isDiscover ? "lg:px-16" : ""}
        title={name}
        actions={
          <>
            <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy link" text={url}>
              <Button aria-label="Copy link">
                <Icon name="link" />
              </Button>
            </CopyToClipboard>
            {can_edit ? (
              <Button onClick={() => setIsEditing(true)}>
                <Icon name="pencil" />
                Edit
              </Button>
            ) : null}
            {can_follow ? <FollowButton wishlistId={id} wishlistName={name} initialValue={following} /> : null}
            <WithTooltip
              tip={checkout_enabled ? null : "None of the products on this wishlist are available for purchase"}
            >
              <NavigationButton
                color="accent"
                href={Routes.checkout_index_url({ params: { wishlist: id } })}
                disabled={!checkout_enabled}
              >
                <Icon name="cart3-fill" />
                Buy this wishlist
              </NavigationButton>
            </WithTooltip>
          </>
        }
      >
        {user ? (
          <a style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }} href={user.profile_url}>
            <img className="user-avatar" src={user.avatar_url} style={{ width: "var(--spacer-5)" }} />
            <h4>{user.name}</h4>
          </a>
        ) : null}
        {description ? <h4>{description}</h4> : null}
      </PageHeader>
      <section className={classNames("p-4 md:p-8", isDiscover && "lg:px-16")}>
        <ProductCardGrid ref={gridRef}>
          {items.map((item) => (
            <WishlistItemCard
              key={item.id}
              wishlistId={id}
              item={item}
              canEdit={can_edit}
              onDelete={() => {
                setItems((prev) => prev.filter((i) => i.id !== item.id));
                // Go back to first page to avoid empty last page
                setPagination(initialPagination);
              }}
            />
          ))}
        </ProductCardGrid>

        {items.length === 0 ? (
          <div className="placeholder">
            <figure>
              <Icon name="gift-fill" />
            </figure>
            {can_edit ? "Products from your wishlist will be displayed here" : "This wishlist is currently empty"}
          </div>
        ) : null}

        {isEditing ? (
          <WishlistEditor
            id={id}
            name={name}
            setName={setName}
            description={description}
            setDescription={setDescription}
            isDiscoverable={!discover_opted_out}
            onClose={() => setIsEditing(false)}
          />
        ) : null}
      </section>
    </>
  );
};

export default register({ component: Wishlist, propParser: createCast() });
