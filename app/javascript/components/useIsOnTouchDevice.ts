import * as React from "react";

import Mobile from "$app/utils/mobile";

import { useRunOnce } from "$app/components/useRunOnce";

export const useIsOnTouchDevice = () => {
  const [isOnTouchDevice, setOnTouchDevice] = React.useState<boolean | null>(null);
  useRunOnce(() => setOnTouchDevice(Mobile.isOnTouchDevice()));

  return isOnTouchDevice;
};
