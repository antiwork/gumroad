import * as React from "react";

import { hasType, isBoolean, isNumber, isRecord, isString } from "$app/utils/guards";
import Mobile from "$app/utils/mobile";

import { useRefToLatest } from "./useRefToLatest";

export type MobileAppAudioPlayerInfo = {
  fileId: string;
  isPlaying: boolean;
  latestMediaLocation?: string;
};

export type ReactNativeMessage =
  | { type: "mobileAppPageChange"; payload: { pageIndex: number } }
  | { type: "mobileAppSettingsSave" }
  | { type: "mobileAppAudioPlayerInfo"; payload: MobileAppAudioPlayerInfo };

// The native app sends this payload both as a message and as a CustomEvent detail, so both
// entry points check it with the same guard.
export const isMobileAppAudioPlayerInfo = (value: unknown): value is MobileAppAudioPlayerInfo =>
  isRecord(value) &&
  isString(value.fileId) &&
  isBoolean(value.isPlaying) &&
  (value.latestMediaLocation === undefined || isString(value.latestMediaLocation));

export const isReactNativeMessage = (data: unknown): data is ReactNativeMessage => {
  if (hasType(data, "mobileAppSettingsSave")) return true;
  if (hasType(data, "mobileAppPageChange")) return isRecord(data.payload) && isNumber(data.payload.pageIndex);
  if (hasType(data, "mobileAppAudioPlayerInfo")) return isMobileAppAudioPlayerInfo(data.payload);
  return false;
};

export const useReactNativeMessage = (handler: (data: ReactNativeMessage) => void) => {
  const handlerRef = useRefToLatest(handler);

  React.useEffect(() => {
    if (!window.ReactNativeWebView) return;
    const target = Mobile.isOnAndroidDevice() ? document : window;
    const listener = (event: MessageEvent) => {
      if (typeof event.data !== "string" || !event.data.startsWith("{")) return;
      let data: unknown;
      try {
        data = JSON.parse(event.data);
      } catch {
        return;
      }
      if (isReactNativeMessage(data)) handlerRef.current(data);
    };
    // @ts-expect-error - React Native sends message events to Android webviews via the document object, not window
    target.addEventListener("message", listener);
    // @ts-expect-error - React Native sends message events to Android webviews via the document object, not window
    return () => target.removeEventListener("message", listener);
  }, []);
};
