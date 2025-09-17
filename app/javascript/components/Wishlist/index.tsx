import * as React from "react";
import { createCast } from "ts-safe-cast";

import { CardProduct } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { RecurrenceId, recurrenceNames } from "$app/utils/recurringPricing";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Card } from "$app/components/Product/Card";
import { Option } from "$app/components/Product/ConfigurationSelector";
import { trackCtaClick } from "$app/components/Product/CtaButton";
import { PageHeader } from "$app/components/ui/PageHeader";
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
}: WishlistProps) => {
  const [name, setName] = React.useState(initialName);
  const [description, setDescription] = React.useState(initialDescription);
  const [items, setItems] = React.useState(initialItems);
  const [isEditing, setIsEditing] = React.useState(false);

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
        <div className="product-card-grid">
          {items.map((item) => (
            <Card
              key={item.id}
              product={{ ...item.product, name: formatName(item) }}
              footerAction={
                item.purchasable && item.giftable ? (
                  <div style={{ padding: 0, display: "grid" }}>
                    <WithTooltip position="top" tip="Gift this product">
                      <a
                        aria-label="Gift this product"
                        href={Routes.checkout_index_url({ params: { gift_wishlist_product: item.id } })}
                        style={{ padding: "var(--spacer-4)", display: "grid" }}
                      >
                        <Icon name="gift-fill" />
                      </a>
                    </WithTooltip>
                  </div>
                ) : null
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
          ))}
        </div>
        {isEditing ? (
          <WishlistEditor
            id={id}
            name={name}
            setName={setName}
            description={description}
            setDescription={setDescription}
            items={items}
            setItems={setItems}
            isDiscoverable={!discover_opted_out}
            onClose={() => setIsEditing(false)}
          />
        ) : null}
      </section>
    </>
  );
};

export default register({ component: Wishlist, propParser: createCast() });
