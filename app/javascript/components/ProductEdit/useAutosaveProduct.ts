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

  const isDirty = !isEqual(product, lastSavedProductRef.current);

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

  React.useEffect(() => {
    if (!isDirty || saving || isBlocked) return;

    clearDebounce();
    debounceTimer.current = window.setTimeout(triggerSave, 3_000);

    return clearDebounce;
  }, [product, isDirty, saving, isBlocked, triggerSave]);

  React.useEffect(() => {
    intervalTimer.current = window.setInterval(triggerSave, 120_000);

    return () => {
      if (intervalTimer.current !== null) {
        clearInterval(intervalTimer.current);
      }
    };
  }, [triggerSave]);
};
