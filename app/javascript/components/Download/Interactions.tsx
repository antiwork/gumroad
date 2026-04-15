import * as React from "react";

import { trackUserActionEvent } from "$app/data/user_action_event";

import { FileItem } from "$app/components/Download/FileList";

type ClickPayload = {
  resourceId: string;
  isDownload: boolean;
  isPost: boolean;
  extension?: string | null;
  type?: string | null;
  isPlaying?: "true" | "false" | null;
  resumeAt?: string | null;
  contentLength?: string | null;
};

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        jsMessage?: {
          postMessage: (message: { type: "click"; payload: ClickPayload }) => void;
        };
      };
    };
    CustomJavaScriptInterface?: {
      onFileClickedEvent: (resourceId: string, isDownload: boolean) => void;
      onPostClickedEvent: (resourceId: string) => void;
    };
    ReactNativeWebView?: {
      postMessage: (message: string) => void;
    };
  }
}

const alwaysOpenOnWebEvents = ["send_to_kindle_click"];

export const NativeAppLink = <Element extends HTMLElement>({
  children,
  eventName,
  file,
  post,
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
  type?: string | null;
  isPlaying?: boolean | null;
  resumeAt?: number | null;
  contentLength?: number | null;
  onWebClick?: () => void;
} & ({ file: FileItem | null; post?: undefined } | { post: { id: string } | null; file?: undefined })) =>
  React.cloneElement(children, {
    onClick: (e: React.MouseEvent<Element>) => {
      const resourceId = file?.id ?? post?.id;
      const openInApp = resourceId && (!eventName || !alwaysOpenOnWebEvents.includes(eventName));
      const appPayload = openInApp
        ? ({
            resourceId,
            isDownload: eventName === "download_click",
            isPost: eventName === "post_click",
            type,
            extension: file?.extension ?? null,
            isPlaying: isPlaying === null ? null : isPlaying ? "true" : "false",
            resumeAt: resumeAt?.toString() ?? null,
            contentLength: contentLength?.toString() ?? null,
          } satisfies ClickPayload)
        : undefined;

      if (window.webkit?.messageHandlers?.jsMessage && appPayload) {
        e.stopPropagation();
        e.preventDefault();
        // Open in the iOS app
        const { extension, ...rest } = appPayload;
        window.webkit.messageHandlers.jsMessage.postMessage({ type: "click", payload: rest });
      } else if (window.CustomJavaScriptInterface && appPayload) {
        e.stopPropagation();
        e.preventDefault();
        // Open in the Android app
        if (eventName === "post_click") {
          window.CustomJavaScriptInterface.onPostClickedEvent(appPayload.resourceId);
        } else {
          window.CustomJavaScriptInterface.onFileClickedEvent(appPayload.resourceId, appPayload.isDownload);
        }
      } else if (window.ReactNativeWebView && appPayload) {
        e.stopPropagation();
        e.preventDefault();
        // Open in the React Native app
        window.ReactNativeWebView.postMessage(JSON.stringify({ type: "click", payload: appPayload }));
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
