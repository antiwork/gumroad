import { X } from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";

import { Button } from "$app/components/Button";
import { WebBuildPlayer, WebBuildPlayerHandle } from "$app/components/Download/WebBuildPlayer";

type Props = {
  title: string;
  frame_url: string;
  content_page_url: string;
};

const Play = () => {
  const { title, frame_url, content_page_url } = cast<Props>(usePage().props);
  const playerRef = React.useRef<WebBuildPlayerHandle>(null);
  // iPhone Safari has no element fullscreen, so the button only shows where it can work.
  const [canFullscreen, setCanFullscreen] = React.useState(false);
  React.useEffect(
    () => setCanFullscreen(document.fullscreenEnabled && "requestFullscreen" in HTMLIFrameElement.prototype),
    [],
  );

  return (
    <div className="scoped-tailwind-preflight flex h-dvh flex-col bg-black">
      <div role="menubar" className="flex items-center bg-background text-sm md:text-base">
        <div className="border-r">
          <a href={content_page_url} aria-label="Back to content" className="flex cursor-pointer p-4 all-unset">
            <X className="size-5" />
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
      <div className="min-h-0 flex-1">
        <WebBuildPlayer ref={playerRef} title={title} frameUrl={frame_url} />
      </div>
    </div>
  );
};

Play.loggedInUserLayout = true;
export default Play;
