import * as React from "react";

import { Button, buttonVariants } from "$app/components/Button";
import { Popover } from "$app/components/Popover";

type Props = { iosAppUrl: string; androidAppUrl: string };

export const OpenInAppButton = ({ iosAppUrl, androidAppUrl }: Props) => (
  <Popover
    trigger={
      <Button asChild>
        <span>Open in app</span>
      </Button>
    }
  >
    <div
      className="mx-auto"
      style={{
        display: "grid",
        textAlign: "center",
        gap: "var(--spacer-4)",
        width: "18rem",
      }}
    >
      <h3>Gumroad Library</h3>
      <div>Download from the App Store</div>
      <div
        style={{
          display: "grid",
          gap: "var(--spacer-4)",
          gridAutoFlow: "column",
          justifyContent: "space-between",
        }}
      >
        <Button asChild>
          <a
            className={buttonVariants({ size: "default", color: "apple" })}
            href={iosAppUrl}
            target="_blank"
            rel="noreferrer"
          >
            <span className="brand-icon brand-icon-apple" />
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
            <span className="brand-icon brand-icon-android" />
            Play Store
          </a>
        </Button>
      </div>
    </div>
  </Popover>
);
