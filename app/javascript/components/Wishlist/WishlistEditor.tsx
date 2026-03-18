import { CheckCircle } from "@boxicons/react";
import * as React from "react";

import { updateWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";

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
    <Sheet open onOpenChange={close}>
      <SheetHeader>{newName || "Untitled"}</SheetHeader>
      {isDiscoverable ? (
        <small className="mt-1 block text-muted">
          <CheckCircle pack="filled" className="size-5" /> Discoverable
        </small>
      ) : null}

      <Fieldset>
        <Label htmlFor={`${uid}-name`}>Name</Label>
        <Input
          id={`${uid}-name`}
          type="text"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          onBlur={() => void update()}
        />
      </Fieldset>
      <Fieldset>
        <Label htmlFor={`${uid}-description`}>Description</Label>
        <Input
          id={`${uid}-description`}
          type="text"
          value={newDescription}
          placeholder="Describe your wishlist"
          onChange={(e) => setNewDescription(e.target.value)}
          onBlur={() => void update()}
        />
      </Fieldset>
    </Sheet>
  );
};
