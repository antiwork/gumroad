import * as React from "react";

import { updateWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

export const WishlistEditor = ({
  id,
  name,
  setName,
  description,
  setDescription,
  isDiscoverable,
  onClose: close,
}: {
  id: string;
  name: string;
  setName: (newName: string) => void;
  description: string | null;
  setDescription: (newDescription: string | null) => void;
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
    <aside className="z-30">
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
    </aside>
  );
};
