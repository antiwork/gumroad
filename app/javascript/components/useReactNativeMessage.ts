import * as React from "react";

import { hasType, isBoolean, isNumber, isRecord, isString } from "$app/utils/guards";
import Mobile from "$app/utils/mobile";

import { useRefToLatest } from "./useRefToLatest";

export type ReactNativeMessage =
  | { type: "mobileAppPageChange"; payload: { pageIndex: number } }
  | { type: "mobileAppSettingsSave" }
  | {
      type: "mobileAppAudioPlayerInfo";
      payload: { fileId: string; isPlaying: boolean; latestMediaLocation?: string };
    };

export const isReactNativeMessage = (data: unknown): data is ReactNativeMessage => {
  if (hasType(data, "mobileAppSettingsSave")) return true;
  if (hasType(data, "mobileAppPageChange")) return isRecord(data.payload) && isNumber(data.payload.pageIndex);
  if (hasType(data, "mobileAppAudioPlayerInfo")) {
    const { payload } = data;
    return (
      isRecord(payload) &&
      isString(payload.fileId) &&
      isBoolean(payload.isPlaying) &&
      (payload.latestMediaLocation === undefined || isString(payload.latestMediaLocation))
    );
  }
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
