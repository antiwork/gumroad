import { usePage } from "@inertiajs/react";
import * as React from "react";

import { showAlert, type AlertPayload } from "$app/components/server-components/Alert";

const SHOWN_FLASH_IDS_KEY = "gumroad_shown_flash_ids";
const MAX_STORED_IDS = 50;

/**
 * Flash payload structure from the server.
 * Includes a unique ID for deduplication.
 */
export type FlashPayload = AlertPayload & { id: string };

/**
 * Get the set of flash IDs that have already been shown.
 * Uses sessionStorage to persist across page navigations within the session.
 */
const getShownFlashIds = (): Set<string> => {
  if (typeof window === "undefined") return new Set();
  try {
    const stored = sessionStorage.getItem(SHOWN_FLASH_IDS_KEY);
    return stored ? new Set(JSON.parse(stored)) : new Set();
  } catch {
    return new Set();
  }
};

/**
 * Mark a flash ID as shown.
 * Keeps only the most recent IDs to prevent unbounded growth.
 */
const markFlashAsShown = (id: string): void => {
  if (typeof window === "undefined") return;
  try {
    const ids = getShownFlashIds();
    ids.add(id);
    // Keep only the most recent IDs
    const idsArray = Array.from(ids).slice(-MAX_STORED_IDS);
    sessionStorage.setItem(SHOWN_FLASH_IDS_KEY, JSON.stringify(idsArray));
  } catch {
    // Ignore storage errors
  }
};

type PageProps = {
  flash?: FlashPayload | null;
};

/**
 * Hook to access raw flash data from props.
 * Use this for inline flash displays (not toasts).
 */
export const useFlashData = (): FlashPayload | null => {
  const { flash } = usePage<PageProps>().props;
  return flash ?? null;
};

/**
 * Hook that handles flash-to-toast conversion with duplicate prevention.
 *
 * Each flash message from the server includes a unique ID. We track shown IDs
 * in sessionStorage so that when the user navigates back (restoring old props
 * from browser history), we don't show the same flash again.
 *
 * This solves the flash persistence bug without requiring unreleased Inertia
 * features or hacky router.replace workarounds.
 */
export const useFlash = (): AlertPayload | null => {
  const { flash } = usePage<PageProps>().props;

  React.useEffect(() => {
    if (!flash?.id || !flash?.message) return;

    const shownIds = getShownFlashIds();
    if (shownIds.has(flash.id)) {
      // Already shown this flash, skip
      return;
    }

    // Mark as shown and display
    markFlashAsShown(flash.id);
    showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);
  }, [flash?.id, flash?.message, flash?.status]);

  return flash ?? null;
};
