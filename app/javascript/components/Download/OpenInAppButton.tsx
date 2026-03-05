import { Android, Apple } from "@boxicons/react";
import * as React from "react";

import { Button, buttonVariants } from "$app/components/Button";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type Props = { iosAppUrl: string; androidAppUrl: string };

export const OpenInAppButton = ({ iosAppUrl, androidAppUrl }: Props) => (
  <Popover>
    <PopoverAnchor>
      <PopoverTrigger asChild>
        <Button>Open in app</Button>
      </PopoverTrigger>
    </PopoverAnchor>
    <PopoverContent sideOffset={4}>
      <div className="mx-auto grid w-72 gap-4 text-center">
        <h3>Gumroad Library</h3>
        <div>Download from the App Store</div>
        <div className="grid grid-flow-col justify-between gap-4">
          <Button asChild>
            <a
              className={buttonVariants({ size: "default", color: "apple" })}
              href={iosAppUrl}
              target="_blank"
              rel="noreferrer"
            >
              <Apple pack="brands" className="size-5" />
              App Store
            </a>
          </Button>
          <Button asChild>
            <a
              className={buttonVariants({ size: "default", color: "android" })}
              href={androidAppUrl}
              target="_blank"
              rel="noreferrer"
            >
              <Android pack="brands" className="size-5" />
              Play Store
            </a>
          </Button>
        </div>
      </div>
    </PopoverContent>
  </Popover>
);
