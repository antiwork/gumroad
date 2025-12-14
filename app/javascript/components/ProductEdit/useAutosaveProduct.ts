import * as React from "react";
import isEqual from "lodash/isEqual";
import { Product } from "./state";

type Options = {
  product: Product;
  lastSavedProductRef: React.MutableRefObject<Product>;
  save: () => Promise<void>;
  saving: boolean;
  isBlocked: boolean;
};

export const useAutosaveProduct = ({
  product,
  lastSavedProductRef,
  save,
  saving,
  isBlocked,
}: Options) => {
  const debounceTimer = React.useRef<number | null>(null);
  const intervalTimer = React.useRef<number | null>(null);

  // TODO(Tri): Optimize with a dirtyRef instead of a deep-equality check
  const isDirty = !isEqual(product, lastSavedProductRef.current);

  // TODO(Tri): Handle `const autosaveErrorCount = React.useRef(0);`

  const clearDebounce = () => {
    if (debounceTimer.current !== null) {
      clearTimeout(debounceTimer.current);
      debounceTimer.current = null;
    }
  };

  const triggerSave = React.useCallback(() => {
    if (saving || isBlocked || !isDirty) return;
    void save();
  }, [saving, isBlocked, isDirty, save]);


  // Autosave after user edits stop
  React.useEffect(() => {
    if (!isDirty || saving || isBlocked) return;

    clearDebounce();
    debounceTimer.current = window.setTimeout(triggerSave, 5_000);

    return clearDebounce;
  }, [product, isDirty, saving, isBlocked, triggerSave]);

  // Periodic safety save
  React.useEffect(() => {
    intervalTimer.current = window.setInterval(triggerSave, 120_000);

    return () => {
      if (intervalTimer.current !== null) {
        clearInterval(intervalTimer.current);
      }
    };
  }, [triggerSave]);
};
