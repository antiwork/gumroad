import * as React from "react";

import { trackUserActionEvent } from "$app/data/user_action_event";

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        jsMessage?: {
          postMessage: (message: {
            type: "click";
            payload: {
              resourceId: string;
              isDownload: boolean;
              isPost: boolean;
              type?: string | null;
              isPlaying?: "true" | "false" | null;
              resumeAt?: string | null;
              contentLength?: string | null;
            };
          }) => void;
        };
      };
    };
    CustomJavaScriptInterface?: {
      onFileClickedEvent: (resourceId: string, isDownload: boolean) => void;
      onPostClickedEvent: (resourceId: string) => void;
    };
  }
}

const alwaysOpenOnWebEvents = ["send_to_kindle_click"];

export const NativeAppLink = <Element extends HTMLElement>({
  children,
  eventName,
  resourceId,
  type = null,
  isPlaying = null,
  resumeAt = null,
  contentLength = null,
  onWebClick,
}: {
  children: React.ReactElement<{ onClick?: (e: React.MouseEvent<Element>) => void }>;
  eventName?:
    | "stream_click"
    | "external_link_click"
    | "play_click"
    | "send_to_kindle_click"
    | "download_click"
    | "post_click"
    | "watch";
  resourceId: string | null;
  type?: string | null;
  isPlaying?: boolean | null;
  resumeAt?: number | null;
  contentLength?: number | null;
  onWebClick?: () => void;
}) =>
  React.cloneElement(children, {
    onClick: (e: React.MouseEvent<Element>) => {
      const openInApp = resourceId && (!eventName || !alwaysOpenOnWebEvents.includes(eventName));

      if (window.webkit?.messageHandlers?.jsMessage && openInApp) {
        e.stopPropagation();
        e.preventDefault();
        // Open in the iOS app
        window.webkit.messageHandlers.jsMessage.postMessage({
          type: "click",
          payload: {
            resourceId,
            isDownload: eventName === "download_click",
            isPost: eventName === "post_click",
            type,
            isPlaying: isPlaying === null ? null : isPlaying ? "true" : "false",
            resumeAt: resumeAt?.toString() ?? null,
            contentLength: contentLength?.toString() ?? null,
          },
        });
      } else if (window.CustomJavaScriptInterface && openInApp) {
        e.stopPropagation();
        e.preventDefault();
        // Open in the Android app
        if (eventName === "post_click") {
          window.CustomJavaScriptInterface.onPostClickedEvent(resourceId);
        } else {
          window.CustomJavaScriptInterface.onFileClickedEvent(resourceId, eventName === "download_click");
        }
      } else {
        children.props.onClick?.(e);
        onWebClick?.();
      }
    },
  });

export const TrackClick: typeof NativeAppLink = (props) => (
  <NativeAppLink
    {...props}
    onWebClick={() => {
      if (props.eventName) {
        void trackUserActionEvent(props.eventName);
      }
    }}
  ></NativeAppLink>
);
