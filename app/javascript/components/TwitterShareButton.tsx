import * as React from "react";

import { NavigationButton } from "$app/components/Button";

// if true
export const TwitterShareButton = ({ url, text = "Join me on @Gumroad!" }: { url: string; text?: string }) => {
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
      <span className="brand-icon brand-icon-twitter" />
      Share on X
    </NavigationButton>
  );
};
