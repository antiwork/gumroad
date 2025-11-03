import * as React from "react";

import { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

type Props = {
  extension: string | null;
  name: string;
  details: React.ReactNode;
  externalLinkUrl: string | null;
  isUploading?: boolean;
  hideIcon?: boolean;
};
export const FileRowContent = ({ extension, name, details, externalLinkUrl, isUploading, hideIcon }: Props) => (
  <>
    {isUploading ? <LoadingSpinner className="size-8" /> : hideIcon ? null : <FileKindIcon extension={extension} />}
    <div>
      <h4>
        {extension === "URL" && externalLinkUrl ? (
          <a href={externalLinkUrl} target="_blank" rel="noopener noreferrer">
            {name}
          </a>
        ) : (
          name
        )}
      </h4>
      <ul className="inline">{details}</ul>
    </div>
  </>
);

const ICON_EXTENSIONS_MAP = {
  "file-earmark-image-fill": FILE_TYPE_EXTENSIONS_MAP.image,
  "file-earmark-music-fill": FILE_TYPE_EXTENSIONS_MAP.audio,
  "file-earmark-play-fill": FILE_TYPE_EXTENSIONS_MAP.video,
  "file-earmark-zip-fill": FILE_TYPE_EXTENSIONS_MAP.zip,
};
export const FileKindIcon = ({ extension }: { extension: string | null }) => (
  <Icon
    name={
      (extension &&
        Object.entries(ICON_EXTENSIONS_MAP).find(([_, extensions]) => extensions.includes(extension))?.[0]) ||
      "file-earmark-text-fill"
    }
    className="type-icon"
  />
);
