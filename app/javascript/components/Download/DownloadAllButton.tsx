import { ChevronDown, Dropbox as DropboxIcon, FileCode } from "@boxicons/react";
import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type Props = { zip_path: string; files: { url: string; filename: string | null }[] };

export const DownloadAllButton = ({ zip_path, files }: Props) => (
  <Popover>
    <PopoverAnchor>
      <PopoverTrigger asChild>
        <Button>
          Download all
          <ChevronDown className="size-5" />
        </Button>
      </PopoverTrigger>
    </PopoverAnchor>
    <PopoverContent sideOffset={4}>
      <div className="grid gap-2">
        <NavigationButton href={zip_path}>
          <FileCode pack="filled" className="size-5" />
          Download as ZIP
        </NavigationButton>
        <Button onClick={() => Dropbox.save({ files })}>
          <DropboxIcon pack="brands" className="size-5" />
          Save to Dropbox
        </Button>
      </div>
    </PopoverContent>
  </Popover>
);
