import { usePage } from "@inertiajs/react";
import * as React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

const SHOWN_FLASH_IDS_KEY = "gumroad_shown_flash_ids";
const MAX_STORED_IDS = 50;

export type FlashPayload = AlertPayload & { id: string };

const getShownFlashIds = (): Set<string> => {
  if (typeof window === "undefined") return new Set();
  try {
    const stored = sessionStorage.getItem(SHOWN_FLASH_IDS_KEY);
    return stored ? new Set(JSON.parse(stored)) : new Set();
  } catch {
    return new Set();
  }
};

const markFlashAsShown = (id: string): void => {
  if (typeof window === "undefined") return;
  try {
    const ids = getShownFlashIds();
    ids.add(id);
    const idsArray = Array.from(ids).slice(-MAX_STORED_IDS);
    sessionStorage.setItem(SHOWN_FLASH_IDS_KEY, JSON.stringify(idsArray));
  } catch {
  }
};

type PageProps = {
  flash?: FlashPayload | null;
};

export const useFlashData = (): FlashPayload | null => {
  const { flash } = usePage<PageProps>().props;
  return flash ?? null;
};

export const useFlash = (): AlertPayload | null => {
  const { flash } = usePage<PageProps>().props;

  React.useEffect(() => {
    if (!flash?.id || !flash?.message) return;

    const shownIds = getShownFlashIds();
    if (shownIds.has(flash.id)) {
      return;
    }

    markFlashAsShown(flash.id);
    showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);
  }, [flash?.id, flash?.message, flash?.status]);

  return flash ?? null;
};
