import * as React from "react";

import { Button } from "$app/components/ui/Button";

const isFbSdkInitialized = () => typeof FB !== "undefined";

export const FacebookShareButton = ({ url, text = "Join me on Gumroad!" }: { url: string; text?: string }) => {
  const shareUrl = `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}&quote=${encodeURIComponent(
    text,
  )}`;
  const handleClick = (ev: React.MouseEvent<HTMLAnchorElement>) => {
    if (!isFbSdkInitialized()) return;

    ev.preventDefault();
    FB.ui({ href: shareUrl, method: "share", quote: text });
  };

  return (
    <Button asChild color="facebook">
      <a href={shareUrl} onClick={handleClick} target="_blank" rel="noopener noreferrer">
        <span className="brand-icon brand-icon-facebook" />
        Share on Facebook
      </a>
    </Button>
  );
};
