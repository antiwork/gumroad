import * as React from "react";

import { deleteWishlistItem, updateWishlist } from "$app/data/wishlists";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { variantLabel } from "$app/utils/labels";
import { recurrenceNames } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { showAlert } from "$app/components/server-components/Alert";
import { WishlistItem } from "$app/components/Wishlist";

const WishlistItemCard = ({
  wishlistId,
  item: { id, product, option, recurrence, quantity },
  onDelete,
}: {
  wishlistId: string;
  item: WishlistItem;
  onDelete: () => void;
}) => {
  const [isDeleting, setIsDeleting] = React.useState(false);

  const price = (product.price_cents + (option?.price_difference_cents || 0)) * quantity;

  const destroy = async () => {
    setIsDeleting(true);

    try {
      await deleteWishlistItem({ wishlistId, wishlistProductId: id });
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
    <div role="listitem">
      <section>
        <figure>
          <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
        </figure>
        <section>
          <h4>
            <a href={product.url} style={{ textDecoration: "none" }}>
              {product.name}
            </a>
          </h4>
          {product.seller ? <a href={product.seller.profile_url}>{product.seller.name}</a> : null}
          <footer>
            <ul>
              <li>
                <strong>Qty:</strong> {quantity}
              </li>
              {option ? (
                <li>
                  <strong>{variantLabel(product.native_type)}:</strong> {option.name}
                </li>
              ) : null}
              {recurrence ? (
                <li>
                  <strong>Membership:</strong> {recurrenceNames[recurrence]}
                </li>
              ) : null}
            </ul>
          </footer>
        </section>
        <section>
          {formatPriceCentsWithCurrencySymbol(product.currency_code, price, { symbolFormat: "long" })}
          <footer>
            <ul>
              <li>
                <button className="link" disabled={isDeleting} onClick={() => void destroy()}>
                  Remove
                </button>
              </li>
            </ul>
          </footer>
        </section>
      </section>
    </div>
  );
};

const WishlistItems = ({
  wishlistId,
  items,
  onItemDeleted,
}: {
  wishlistId: string;
  items: WishlistItem[];
  onItemDeleted: (id: string) => void;
}) =>
  items.length ? (
    <div className="cart" role="list" aria-label="Wishlist items">
      {items.map((item) => (
        <WishlistItemCard key={item.id} wishlistId={wishlistId} item={item} onDelete={() => onItemDeleted(item.id)} />
      ))}
    </div>
  ) : (
    <div className="placeholder">
      <figure>
        <Icon name="gift-fill" />
      </figure>
      Products from your wishlist will be displayed here
    </div>
  );

export const WishlistEditor = ({
  id,
  name,
  setName,
  description,
  setDescription,
  items,
  setItems,
  isDiscoverable,
  onClose: close,
}: {
  id: string;
  name: string;
  setName: (newName: string) => void;
  description: string | null;
  setDescription: (newDescription: string | null) => void;
  items: WishlistItem[];
  setItems: React.Dispatch<React.SetStateAction<WishlistItem[]>>;
  isDiscoverable: boolean;
  onClose: () => void;
}) => {
  const [newName, setNewName] = React.useState(name);
  const [newDescription, setNewDescription] = React.useState(description ?? "");
  const uid = React.useId();

  const update = async () => {
    const descriptionValue = newDescription || null;
    if (newName === name && descriptionValue === description) return;

    try {
      await updateWishlist({ id, name: newName, description: descriptionValue });
      setName(newName);
      setDescription(descriptionValue);
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  return (
    <aside>
      <header>
        <div>
          <h2>{newName || "Untitled"}</h2>
          {isDiscoverable ? (
            <small className="text-muted mt-1">
              <Icon name="solid-check-circle" /> Discoverable
            </small>
          ) : null}
        </div>
        <button className="close" aria-label="Close" onClick={close} />
      </header>

      <fieldset>
        <label htmlFor={`${uid}-name`}>Name</label>
        <input
          id={`${uid}-name`}
          type="text"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          onBlur={() => void update()}
        />
      </fieldset>
      <fieldset>
        <label htmlFor={`${uid}-description`}>Description</label>
        <input
          id={`${uid}-description`}
          type="text"
          value={newDescription}
          placeholder="Describe your wishlist"
          onChange={(e) => setNewDescription(e.target.value)}
          onBlur={() => void update()}
        />
      </fieldset>

      <fieldset>
        <label>Products</label>
        <WishlistItems
          wishlistId={id}
          items={items}
          onItemDeleted={(id) => setItems((items) => items.filter((item) => item.id !== id))}
        />
      </fieldset>
    </aside>
  );
};
