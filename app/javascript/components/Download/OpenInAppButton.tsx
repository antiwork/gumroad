import * as React from "react";

import { Popover } from "$app/components/Popover";

type Props = { iosAppUrl: string; androidAppUrl: string };

export const OpenInAppButton = ({ iosAppUrl, androidAppUrl }: Props) => (
  <Popover trigger={<span className="button">Open in app</span>}>
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
        <a className="button button-apple" href={iosAppUrl} target="_blank" rel="noreferrer">
          App Store
        </a>
        <a className="button button-android" href={androidAppUrl} target="_blank" rel="noreferrer">
          Play Store
        </a>
      </div>
    </div>
  </Popover>
);
