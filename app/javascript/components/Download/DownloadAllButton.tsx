import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

type Props = { zip_path: string; files: { url: string; filename: string | null }[] };

export const DownloadAllButton = ({ zip_path, files }: Props) => (
  <Popover
    trigger={
      <div className="button">
        Download all
        <Icon name="outline-cheveron-down" />
      </div>
    }
  >
    <div className="grid gap-2">
      <NavigationButton href={zip_path}>
        <Icon name="file-earmark-binary-fill" />
        Download as ZIP
      </NavigationButton>
      <Button onClick={() => Dropbox.save({ files })}>
        <Icon name="dropbox" />
        Save to Dropbox
      </Button>
    </div>
  </Popover>
);
