import { Link as LinkIcon } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { TwitterShareButton } from "$app/components/TwitterShareButton";

export const ShareButtons = ({
  url,
  twitterText,
  facebookText,
}: {
  url: string;
  twitterText: string;
  facebookText: string;
}) => (
  <div className="flex flex-wrap gap-2">
    <TwitterShareButton url={url} text={twitterText} />
    <FacebookShareButton url={url} text={facebookText} />
    <CopyToClipboard text={url} tooltipPosition="top">
      <Button color="primary">
        <LinkIcon className="size-5" />
        Copy URL
      </Button>
    </CopyToClipboard>
  </div>
);
