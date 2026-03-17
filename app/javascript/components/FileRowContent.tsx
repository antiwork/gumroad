import { FileDetail, FileZip, Image, MusicAlt, PlayCircle, type BoxIconProps } from "@boxicons/react";
import * as React from "react";

import { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { InlineList } from "$app/components/ui/InlineList";

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
      <InlineList>{details}</InlineList>
    </div>
  </>
);

const FILE_KIND_ICONS: [React.ComponentType<BoxIconProps>, string[]][] = [
  [Image, FILE_TYPE_EXTENSIONS_MAP.image],
  [MusicAlt, FILE_TYPE_EXTENSIONS_MAP.audio],
  [PlayCircle, FILE_TYPE_EXTENSIONS_MAP.video],
  [FileZip, FILE_TYPE_EXTENSIONS_MAP.zip],
];
export const FileKindIcon = ({ extension }: { extension: string | null }) => {
  const match = extension && FILE_KIND_ICONS.find(([, exts]) => exts.includes(extension));
  const Component = match ? match[0] : FileDetail;
  return <Component pack="filled" className="type-icon size-5" />;
};
