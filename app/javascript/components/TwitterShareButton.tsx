import { TwitterX } from "@boxicons/react";
import * as React from "react";

import { NavigationButton } from "$app/components/Button";

export const TwitterShareButton = ({
  url,
  text = "Join me on @Gumroad!",
  children = "Share on X",
}: {
  url: string;
  text?: string;
  children?: React.ReactNode;
}) => {
  const shareUrl = `https://twitter.com/intent/tweet?url=${encodeURIComponent(url)}&text=${encodeURIComponent(text)}`;

  const handleClick = (ev: React.MouseEvent<HTMLAnchorElement>) => {
    ev.preventDefault();

    const popupHeight = 450;
    const popupWidth = 550;
    const left = (screen.width - popupWidth) / 2;

    window.open(shareUrl, "Twitter", `height=${popupHeight},width=${popupWidth},left=${left}`);
  };

  return (
    <NavigationButton color="twitter" onClick={handleClick} href={shareUrl} target="_blank" rel="noopener noreferrer">
      <TwitterX pack="brands" className="size-5" />
      {children}
    </NavigationButton>
  );
};
