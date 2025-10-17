import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";

type Props = { zip_path: string; files: { url: string; filename: string | null }[] };

export const DownloadAllButton = ({ zip_path, files }: Props) => (
  <Popover
    trigger={
      <div className="inline-flex items-center justify-center gap-2 cursor-pointer no-underline text-base leading-[1.4] px-4 py-3 rounded border [border-color:rgb(var(--color)/var(--border-alpha))] bg-transparent text-current transition-transform ease-out duration-150 hover:-translate-x-1 hover:-translate-y-1 hover:shadow-[0.25rem_0.25rem_0_currentColor]">
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
