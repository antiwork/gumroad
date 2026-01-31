import * as React from "react";

import { Button } from "$app/components/ui/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type Props = { zip_path: string; files: { url: string; filename: string | null }[] };

export const DownloadAllButton = ({ zip_path, files }: Props) => (
  <Popover>
    <PopoverAnchor>
      <PopoverTrigger asChild>
        <Button>
          Download all
          <Icon name="outline-cheveron-down" />
        </Button>
      </PopoverTrigger>
    </PopoverAnchor>
    <PopoverContent sideOffset={4}>
      <div className="grid gap-2">
        <Button asChild>
          <a href={zip_path}>
            <Icon name="file-earmark-binary-fill" />
            Download as ZIP
          </a>
        </Button>
        <Button onClick={() => Dropbox.save({ files })}>
          <Icon name="dropbox" />
          Save to Dropbox
        </Button>
      </div>
    </PopoverContent>
  </Popover>
);
