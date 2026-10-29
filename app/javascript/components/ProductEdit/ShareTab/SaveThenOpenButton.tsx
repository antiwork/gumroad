import * as React from "react";

import { Button } from "$app/components/Button";
import { useProductEditContext } from "$app/components/ProductEdit/state";

// Leaving the editor drops unsaved edits, and Layout warns on unload only during uploads.
export const SaveThenOpenButton = ({
  href,
  getHref,
  color,
  children,
}: {
  // getHref runs after the save, for destinations that only exist once the product is saved.
  href?: string;
  getHref?: () => Promise<string | null>;
  color?: "primary";
  children: React.ReactNode;
}) => {
  const { save } = useProductEditContext();
  const [busy, setBusy] = React.useState(false);

  const open = async () => {
    setBusy(true);
    const destination = (await save()) ? (href ?? (await getHref?.()) ?? null) : null;
    if (destination) window.location.href = destination;
    else setBusy(false);
  };

  return (
    <Button color={color} disabled={busy} onClick={() => void open()}>
      {children}
    </Button>
  );
};
