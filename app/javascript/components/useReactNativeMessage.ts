import * as React from "react";
import { cast } from "ts-safe-cast";

import Mobile from "$app/utils/mobile";

import { useRefToLatest } from "./useRefToLatest";

export type ReactNativeMessage =
  | { type: "mobileAppPageChange"; payload: { pageIndex: number } }
  | {
      type: "mobileAppAudioPlayerInfo";
      payload: { fileId: string; isPlaying: boolean; latestMediaLocation?: string };
    };

export const useReactNativeMessage = (handler: (data: ReactNativeMessage) => void) => {
  const handlerRef = useRefToLatest(handler);

  React.useEffect(() => {
    if (!window.ReactNativeWebView) return;
    const target = Mobile.isOnAndroidDevice() ? document : window;
    const listener = (event: MessageEvent) => {
      if (typeof event.data !== "string" || !event.data.startsWith("{")) return;
      let data: ReactNativeMessage;
      try {
        data = cast<ReactNativeMessage>(JSON.parse(event.data));
      } catch {
        return;
      }
      handlerRef.current(data);
    };
    // @ts-expect-error - React Native sends message events to Android webviews via the document object, not window
    target.addEventListener("message", listener);
    // @ts-expect-error - React Native sends message events to Android webviews via the document object, not window
    return () => target.removeEventListener("message", listener);
  }, []);
};
