import { X } from "@boxicons/react";
import * as React from "react";

import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

// Nudges sellers who attached a PDF but no EPUB to also offer an EPUB version,
// since EPUB text reflows and is much nicer to read on phones and e-readers
// (and is the format Send to Kindle works best with). Dismissal is kept in
// sessionStorage on purpose — this is a lightweight hint, not a persistent
// setting, so we avoid adding a database column for it.
export const EpubNudge = () => {
  const { id, product } = useProductEditContext();
  const storageKey = `epub-nudge-dismissed-${id}`;

  const [dismissed, setDismissed] = React.useState(() => {
    try {
      return sessionStorage.getItem(storageKey) === "true";
    } catch {
      return false;
    }
  });

  const activeFiles = product.files.filter((file) => file.status.type !== "removed");
  const hasPdf = activeFiles.some((file) => file.extension === "PDF");
  const hasEpub = activeFiles.some((file) => file.extension === "EPUB");

  if (dismissed || !hasPdf || hasEpub) return null;

  const dismiss = () => {
    setDismissed(true);
    try {
      sessionStorage.setItem(storageKey, "true");
    } catch {
      // Storage can be unavailable (e.g. strict privacy modes); the nudge will
      // simply reappear next session, which is harmless.
    }
  };

  return (
    <Alert role="status" variant="info" className="m-4 mb-0">
      <div className="flex items-start gap-2">
        <p className="flex-1">
          Buyers read on phones and e-readers — consider adding an EPUB (electronic publication) version of your PDF.
        </p>
        <button aria-label="Dismiss" onClick={dismiss} className="cursor-pointer all-unset">
          <X className="size-5" />
        </button>
      </div>
    </Alert>
  );
};
