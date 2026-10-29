import * as React from "react";

import { request } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";

// Must match ProductBuilds::PlayerDocument::SANDBOX: no allow-same-origin, so the build runs on an
// opaque origin and cannot read this page or its cookies.
const SANDBOX = "allow-scripts allow-pointer-lock";
const SAVE_MESSAGE_TYPE = "gumroad:build-save";

type SaveChanges = { clear: boolean; remove: string[]; set: Record<string, string> };

const isSaveChanges = (value: unknown): value is SaveChanges =>
  typeof value === "object" &&
  value !== null &&
  "clear" in value &&
  typeof value.clear === "boolean" &&
  "remove" in value &&
  Array.isArray(value.remove) &&
  value.remove.every((key) => typeof key === "string") &&
  "set" in value &&
  typeof value.set === "object" &&
  value.set !== null &&
  Object.values(value.set).every((entry) => typeof entry === "string");

const saveChangesFrom = (data: unknown): SaveChanges | null =>
  typeof data === "object" &&
  data !== null &&
  "type" in data &&
  data.type === SAVE_MESSAGE_TYPE &&
  "changes" in data &&
  isSaveChanges(data.changes)
    ? data.changes
    : null;

export type WebBuildPlayerHandle = { enterFullscreen: () => void };

export const WebBuildPlayer = React.forwardRef<WebBuildPlayerHandle, { token: string; title: string }>(
  ({ token, title }, ref) => {
    const frameRef = React.useRef<HTMLIFrameElement>(null);

    React.useImperativeHandle(ref, () => ({
      // The browser refuses fullscreen without a user gesture; the button press is one, so a refusal
      // here leaves the game playing in the page.
      enterFullscreen: () => void frameRef.current?.requestFullscreen().catch(() => undefined),
    }));

    // The frame's storage shim sends its writes here in batches; only this page can send them on,
    // because the frame has no cookies. keepalive lets the last batch out while the page unloads.
    React.useEffect(() => {
      let alertedSaveFailure = false;
      const onMessage = (event: MessageEvent) => {
        if (event.source !== frameRef.current?.contentWindow) return;
        const changes = saveChangesFrom(event.data);
        if (!changes) return;

        void request({
          url: Routes.url_redirect_build_save_path(token),
          method: "PATCH",
          accept: "json",
          data: { clear: changes.clear, remove: changes.remove, set: { ...changes.set } },
          keepalive: true,
        })
          .then((response) => {
            if (!response.ok) throw new Error();
          })
          .catch(() => {
            if (alertedSaveFailure) return;
            alertedSaveFailure = true;
            showAlert("Your progress could not be saved. Keep this page open and try again later.", "error");
          });
      };
      window.addEventListener("message", onMessage);
      return () => window.removeEventListener("message", onMessage);
    }, [token]);

    return (
      <div className="aspect-video w-full overflow-hidden rounded bg-black">
        <iframe
          ref={frameRef}
          src={Routes.url_redirect_play_path(token)}
          title={title}
          sandbox={SANDBOX}
          allow="fullscreen; autoplay; gamepad"
          className="block size-full border-0"
          onLoad={() => frameRef.current?.focus()}
        />
      </div>
    );
  },
);
WebBuildPlayer.displayName = "WebBuildPlayer";
