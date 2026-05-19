import { Facebook } from "@boxicons/react";
import * as React from "react";

import { NavigationButton } from "$app/components/Button";

export const FacebookShareButton = ({ url, text = "Join me on Gumroad!" }: { url: string; text?: string }) => {
  const shareUrl = `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}&quote=${encodeURIComponent(
    text,
  )}`;

  return (
    <NavigationButton color="facebook" href={shareUrl} target="_blank" rel="noopener noreferrer">
      <Facebook pack="brands" className="size-5" />
      Share on Facebook
    </NavigationButton>
  );
};
