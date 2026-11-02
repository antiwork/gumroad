import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";

import { Button, NavigationButton } from "$app/components/Button";
import { useCanFullscreen, WebBuildPlayer, WebBuildPlayerHandle } from "$app/components/Download/WebBuildPlayer";

type Props = {
  title: string;
  frame_url: string;
  product_url: string;
};

const Show = () => {
  const { title, frame_url, product_url } = cast<Props>(usePage().props);
  const playerRef = React.useRef<WebBuildPlayerHandle>(null);
  const canFullscreen = useCanFullscreen();

  return (
    <div className="scoped-tailwind-preflight flex h-dvh flex-col bg-black">
      <div className="flex items-center gap-2 bg-background p-2 text-sm">
        <h1 className="flex-1 truncate px-2">{title}</h1>
        {canFullscreen ? (
          <Button size="sm" onClick={() => playerRef.current?.enterFullscreen()}>
            Full screen
          </Button>
        ) : null}
        {/* A new tab: inside an X card this page is a frame, and the product page must not load in it. */}
        <NavigationButton size="sm" color="accent" href={product_url} target="_blank" rel="noopener">
          Get it on Gumroad
        </NavigationButton>
      </div>
      <div className="min-h-0 flex-1">
        <WebBuildPlayer ref={playerRef} title={title} frameUrl={frame_url} />
      </div>
    </div>
  );
};

Show.publicLayout = true;
export default Show;
