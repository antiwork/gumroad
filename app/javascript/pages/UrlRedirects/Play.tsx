import { ArrowLeft } from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useCanFullscreen, WebBuildPlayer, WebBuildPlayerHandle } from "$app/components/Download/WebBuildPlayer";

type Props = {
  title: string;
  is_mobile_app_web_view: boolean;
  frame_url: string;
  content_page_url: string;
  // Null for a seller trying their own build, which is not a play.
  heartbeat_url: string | null;
  heartbeat_interval_ms: number;
};

// Keeps the play session this page load started open, one row per load (see
// ProductBuildPlaySession). The beats stop when the page goes away, and that is what ends the
// session: the last beat is its end, so its length is final.
const usePlayHeartbeat = (url: string | null, intervalMs: number) => {
  React.useEffect(() => {
    if (!url) return;

    let beatUrl = url;
    // A beat that resumed a session after a long gap answers with the new session's path.
    const beat = (keepalive = false) => {
      void request({ method: "POST", accept: "json", url: beatUrl, keepalive })
        .then(async (response) => {
          if (response.status !== 200) return;
          const { heartbeat_path } = cast<{ heartbeat_path?: string }>(await response.json());
          if (heartbeat_path) beatUrl = heartbeat_path;
        })
        .catch(() => undefined);
    };
    beat();
    const interval = window.setInterval(() => beat(), intervalMs);
    // A closing page can still send a keepalive request, which saves the last stretch rather than
    // ending the session at the previous beat.
    const onPageHide = () => beat(true);
    window.addEventListener("pagehide", onPageHide);

    return () => {
      window.clearInterval(interval);
      window.removeEventListener("pagehide", onPageHide);
    };
  }, [url, intervalMs]);
};

const Play = () => {
  const { title, is_mobile_app_web_view, frame_url, content_page_url, heartbeat_url, heartbeat_interval_ms } =
    cast<Props>(usePage().props);
  const playerRef = React.useRef<WebBuildPlayerHandle>(null);
  const canFullscreen = useCanFullscreen();

  usePlayHeartbeat(heartbeat_url, heartbeat_interval_ms);

  return (
    <div className="scoped-tailwind-preflight flex h-dvh flex-col bg-black">
      {/* The app's player has its own header and back control, so the page's bar would be a second one. */}
      {is_mobile_app_web_view ? null : (
        <div role="menubar" className="flex items-center bg-background text-sm md:text-base">
          <div className="border-r">
            {/* Labelled, not a bare icon: this tab's only exit, and a buyer could read × as "quit the game". */}
            <a
              href={content_page_url}
              className="flex cursor-pointer items-center gap-2 p-4 whitespace-nowrap all-unset"
            >
              <ArrowLeft className="size-5" />
              Back to content
            </a>
          </div>
          <h1 className="flex-1 truncate p-4">{title}</h1>
          {canFullscreen ? (
            <div className="p-2">
              <Button size="sm" onClick={() => playerRef.current?.enterFullscreen()}>
                Full screen
              </Button>
            </div>
          ) : null}
        </div>
      )}
      <div className="min-h-0 flex-1">
        <WebBuildPlayer ref={playerRef} title={title} frameUrl={frame_url} />
      </div>
    </div>
  );
};

Play.loggedInUserLayout = true;
export default Play;
