import * as React from "react";

import { showAlert } from "$app/components/server-components/Alert";

// Must match ProductBuilds::PlayerDocument::SANDBOX: no allow-same-origin, so the build runs on an
// opaque origin and cannot read this page or its cookies.
const SANDBOX = "allow-scripts allow-pointer-lock";
const SAVE_FAILED_MESSAGE_TYPE = "gumroad:build-save-failed";

const isSaveFailedMessage = (data: unknown) =>
  typeof data === "object" && data !== null && "type" in data && data.type === SAVE_FAILED_MESSAGE_TYPE;

export type WebBuildPlayerHandle = { enterFullscreen: () => void };

// Fills its container. The build saves on its own, under the grant in frameUrl; this page only
// tells the buyer when a save fails.
export const WebBuildPlayer = React.forwardRef<WebBuildPlayerHandle, { title: string; frameUrl: string }>(
  ({ title, frameUrl }, ref) => {
    const frameRef = React.useRef<HTMLIFrameElement>(null);

    React.useImperativeHandle(ref, () => ({
      // The browser refuses fullscreen without a user gesture; the button press is one, so a refusal
      // here leaves the game playing in the page.
      enterFullscreen: () => void frameRef.current?.requestFullscreen().catch(() => undefined),
    }));

    React.useEffect(() => {
      let alerted = false;
      const onMessage = (event: MessageEvent) => {
        if (alerted || event.source !== frameRef.current?.contentWindow || !isSaveFailedMessage(event.data)) return;
        alerted = true;
        showAlert("Your progress could not be saved. Keep this tab open and try again later.", "error");
      };
      window.addEventListener("message", onMessage);
      return () => window.removeEventListener("message", onMessage);
    }, []);

    return (
      <iframe
        ref={frameRef}
        src={frameUrl}
        title={title}
        sandbox={SANDBOX}
        allow="fullscreen; autoplay; gamepad"
        className="block size-full border-0 bg-black"
        onLoad={() => frameRef.current?.focus()}
      />
    );
  },
);
WebBuildPlayer.displayName = "WebBuildPlayer";
