import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Alert } from "$app/components/ui/Alert";

type FlashData = {
  warning?: string;
};

export const WarningFlash: React.FC = () => {
  const page = usePage();
  // Access flash from page.flash (not page.props.flash) - this data does NOT persist in history state
  const flash = (page as unknown as { flash: FlashData }).flash;

  if (flash?.warning) {
    return <Alert variant="danger">{flash.warning}</Alert>;
  }

  return null;
};
