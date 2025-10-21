import { Content, findParentNodeClosestToPos, Mark, Node as TiptapNode } from "@tiptap/core";
import { LinkOptions as BaseLinkOptions } from "@tiptap/extension-link";
import { Node as ProseMirrorNode } from "@tiptap/pm/model";
import { EditorContent, NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { RichContent } from "$app/parsers/richContent";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { FileRow, shouldShowSubtitlesForFile } from "$app/components/Download/FileList";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { License, useContentFiles } from "$app/components/server-components/DownloadPage/WithContent";
import { titleWithFallback } from "$app/components/TiptapExtensions/FileEmbedGroup";
import { FileUpload } from "$app/components/TiptapExtensions/FileUpload";
import { LicenseKey, LicenseProvider } from "$app/components/TiptapExtensions/LicenseKey";
import { LongAnswer } from "$app/components/TiptapExtensions/LongAnswer";
import { ExternalMediaFileEmbed } from "$app/components/TiptapExtensions/MediaEmbed";
import { MoreLikeThis } from "$app/components/TiptapExtensions/MoreLikeThis";
import { Posts } from "$app/components/TiptapExtensions/Posts";
import { ShortAnswer } from "$app/components/TiptapExtensions/ShortAnswer";
import { useRunOnce } from "$app/components/useRunOnce";

type SaleInfo = { sale_id: string; product_id: string | null; product_permalink: string | null };

export const RichContentView = ({
  richContent,
  saleInfo,
  license,
}: {
  richContent: RichContent | null;
  saleInfo: SaleInfo | null;
  license: License | null;
}) => {
  const editor = useRichTextEditor({
    ariaLabel: "Product content",
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- to be fixed with product edit refactor
    initialValue: richContent as Content,
    editable: false,
    extensions: [
      Link.configure({ saleInfo }),
      TiptapLink.configure({ saleInfo }),
      TiptapButton.configure({ saleInfo }),
      FileEmbed,
      FileEmbedGroup,
      ExternalMediaFileEmbed,
      LicenseKey,
      Posts,
      MoreLikeThis.configure({ productId: saleInfo?.product_id ?? "" }),
      ShortAnswer.extend({ draggable: false }),
      LongAnswer.extend({ draggable: false }),
      FileUpload.extend({ draggable: false }),
    ],
  });
  const licenseInfo = {
    licenseKey: license?.license_key ?? null,
    isMultiSeatLicense: license?.is_multiseat_license ?? null,
    seats: license?.seats ?? null,
  };

  return (
    <LicenseProvider value={licenseInfo}>
      <EditorContent className="rich-text" editor={editor} />
    </LicenseProvider>
  );
};

const SALE_INFO_PLACEHOLDER_QUERY_PARAM = "__sale_info__";

const addSaleInfoQueryParams = (href: string, saleInfo: SaleInfo | null) => {
  if (!saleInfo) return href;

  try {
    const url = new URL(href);
    if (!url.searchParams.has(SALE_INFO_PLACEHOLDER_QUERY_PARAM)) return href;

    url.searchParams.delete(SALE_INFO_PLACEHOLDER_QUERY_PARAM);
    url.searchParams.set("sale_id", saleInfo.sale_id);
    url.searchParams.set("product_id", saleInfo.product_id || "");
    url.searchParams.set("product_permalink", saleInfo.product_permalink || "");

    return url.href;
  } catch {
    return href;
  }
};

const Link = Mark.create<BaseLinkOptions & { saleInfo: SaleInfo | null }>({
  name: "link",
  addAttributes: () => ({
    href: { default: null },
    target: { default: "_blank" },
    rel: { default: "noopener noreferrer nofollow" },
    class: { default: null },
  }),
  renderHTML({ HTMLAttributes }) {
    return [
      "a",
      {
        ...HTMLAttributes,
        href: addSaleInfoQueryParams(cast<string>(HTMLAttributes.href), this.options.saleInfo),
        target: "_blank",
      },
      0,
    ];
  },
});

const TiptapLink = TiptapNode.create<{ saleInfo: SaleInfo | null }>({
  name: "tiptap-link",
  group: "inline",
  inline: true,
  content: "text*",
  addAttributes: () => ({ href: { default: null } }),
  renderHTML({ HTMLAttributes }) {
    return [
      "a",
      {
        ...HTMLAttributes,
        target: "_blank",
        rel: "noopener noreferrer nofollow",
        href: addSaleInfoQueryParams(cast<string>(HTMLAttributes.href), this.options.saleInfo),
      },
      0,
    ];
  },
});

const TiptapButton = TiptapNode.create<{ saleInfo: SaleInfo | null }>({
  name: "button",
  group: "block",
  content: "inline+",
  addAttributes: () => ({ href: { default: null } }),
  renderHTML({ HTMLAttributes }) {
    return [
      "a",
      {
        ...HTMLAttributes,
        class: "button primary",
        target: "_blank",
        rel: "noopener noreferrer nofollow",
        href: addSaleInfoQueryParams(cast<string>(HTMLAttributes.href), this.options.saleInfo),
      },
      0,
    ];
  },
});

const FileEmbedNodeView = ({ node, getPos, editor }: NodeViewProps) => {
  const contentFiles = useContentFiles();
  const file = contentFiles.find((file) => file.id === node.attrs.id);
  const [playingAudioForId, setPlayingAudioForId] = React.useState<null | string>(null);
  const pos = getPos();
  const isInGroup =
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Tiptap types are wrong
    pos !== undefined &&
    !!findParentNodeClosestToPos(
      editor.state.tr.doc.resolve(pos),
      (parent) => parent.type.name === FileEmbedGroup.name,
    );
  const fileRow = file ? (
    <FileRow
      file={file}
      playingAudioForId={playingAudioForId}
      setPlayingAudioForId={setPlayingAudioForId}
      isEmbed
      isTreeItem={isInGroup}
      collapsed={!!node.attrs.collapsed}
    />
  ) : null;
  return file ? (
    <NodeViewWrapper>
      {shouldShowSubtitlesForFile(file) ? (
        <div role="tree" style={{ border: 0 }}>
          {fileRow}
        </div>
      ) : (
        fileRow
      )}
    </NodeViewWrapper>
  ) : null;
};

const FileEmbed = TiptapNode.create({
  name: "fileEmbed",
  group: "block",
  selectable: false,
  addAttributes: () => ({ id: { default: null }, collapsed: { default: false } }),
  parseHTML: () => [{ tag: "file-embed" }],
  renderHTML: ({ HTMLAttributes }) => ["file-embed", HTMLAttributes],
  addNodeView: () => ReactNodeViewRenderer(FileEmbedNodeView),
});

export type FileDownloadInfo = {
  id: string;
  status?: string;
  url: string;
  size: number;
  s3Url?: string | null;
  downloadFileName?: string | undefined;
};
type FilesAndFoldersDownloadInfo = {
  downloadableFiles: FileDownloadInfo[];
  isMobileAppWebView: boolean;
  pdfStampingEnabled: boolean;
  getFolderArchive: (folderId: string) => Promise<{ url: string | null }>;
  getDownloadUrlsForFiles: (ids: string[]) => Promise<{ url: string; filename: string | null }[]>;
  hasStreamable: (ids: string[]) => boolean;
};
const FilesAndFoldersDownloadInfoContext = React.createContext<FilesAndFoldersDownloadInfo | null>(null);
export const FilesAndFoldersDownloadInfoProvider = FilesAndFoldersDownloadInfoContext.Provider;

const useFilesAndFoldersDownloadInfo = () =>
  assertDefined(
    React.useContext(FilesAndFoldersDownloadInfoContext),
    "Download info is not set. Make sure FilesAndFoldersDownloadInfoProvider is used.",
  );

const ARCHIVE_FETCH_INTERVAL_DURATION_IN_MS = 5000;
// The actual archive size limit is 500 MB (524288000B)
const ARCHIVE_SIZE_LIMIT_IN_BYTES = 500000000;
const FileEmbedGroupNodeView = ({ node }: NodeViewProps) => {
  const [expanded, setExpanded] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);
  const downloadInfo = useFilesAndFoldersDownloadInfo();

  const [downloadableFilesInFolder, hasStreamable] = React.useMemo(() => {
    const files: FileDownloadInfo[] = [];
    const fileIds: string[] = [];
    node.content.descendants((c) => {
      if (!c.attrs.id) return;
      const fileId = cast<string>(c.attrs.id);
      fileIds.push(fileId);
      const file = downloadInfo.downloadableFiles.find((f) => f.id === fileId);
      if (file) files.push(file);
    });
    return [files, downloadInfo.hasStreamable(fileIds)];
  }, [node.content.childCount, downloadInfo]);

  const canGenerateArchive =
    downloadableFilesInFolder.reduce((total, file) => total + file.size, 0) < ARCHIVE_SIZE_LIMIT_IN_BYTES;
  const folderTitle = titleWithFallback(node.attrs.name);
  const downloadAllButtonIsVisible = !(
    downloadInfo.isMobileAppWebView ||
    downloadInfo.pdfStampingEnabled ||
    downloadableFilesInFolder.length === 0 ||
    (!canGenerateArchive && downloadableFilesInFolder.length > 1)
  );
  const folderId = cast<string>(node.attrs.uid);

  useRunOnce(() => {
    const groupWrapper = ref.current?.querySelector("[data-node-view-content]")?.firstElementChild;
    if (groupWrapper instanceof HTMLElement) groupWrapper.style.display = "contents";
  });
  const uid = React.useId();

  return (
    <NodeViewWrapper>
      <div role="tree" ref={ref}>
        <div role="treeitem" aria-expanded={expanded}>
          <div className="content" onClick={() => setExpanded(!expanded)} contentEditable={false}>
            <Icon name="solid-folder-open" className="type-icon" />
            <div>
              <h4>{folderTitle}</h4>
            </div>
          </div>
          {downloadAllButtonIsVisible ? (
            <div className="actions">
              <FileGroupDownloadAllButton folderId={folderId} files={downloadableFilesInFolder} />
            </div>
          ) : null}
          {hasStreamable ? (
            <NodeViewContent id={uid} role="group" />
          ) : (
            <div role="group">
              <NodeViewContent id={uid} className="rows" />
            </div>
          )}
        </div>
      </div>
    </NodeViewWrapper>
  );
};

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    fileEmbedGroup: {
      insertFileEmbedGroup: (options: { content: ProseMirrorNode[]; pos: number }) => ReturnType;
    };
  }
}

const FileEmbedGroup = TiptapNode.create({
  name: "fileEmbedGroup",
  content: "fileEmbed*",
  group: "block",
  selectable: false,
  draggable: true,
  atom: true,
  addAttributes: () => ({ uid: { default: null }, name: { default: null } }),
  parseHTML: () => [{ tag: "file-embed-group" }],
  renderHTML: ({ HTMLAttributes }) => ["file-embed-group", HTMLAttributes, 0],
  addNodeView() {
    return ReactNodeViewRenderer(FileEmbedGroupNodeView);
  },
});

const FileGroupDownloadAllButton = ({ folderId, files }: { folderId: string; files: FileDownloadInfo[] }) => {
  const downloadInfo = useFilesAndFoldersDownloadInfo();

  const [isArchiving, setIsArchiving] = React.useState(false);
  const archiveFetchIntervalRef = React.useRef<ReturnType<typeof setInterval> | undefined>();
  React.useEffect(() => {
    if (isArchiving) {
      archiveFetchIntervalRef.current = setInterval(
        asyncVoid(async () => {
          try {
            const archive = await downloadInfo.getFolderArchive(folderId);
            if (archive.url) {
              setIsArchiving(false);
              showAlert(
                `<span>Your ZIP file is ready! <a href="${archive.url}" target="_blank">Download</a></span>`,
                "success",
                { html: true },
              );
              clearInterval(archiveFetchIntervalRef.current);
            }
          } catch (e) {
            setIsArchiving(false);
            assertResponseError(e);
            showAlert(e.message, "error");
          }
        }),
        ARCHIVE_FETCH_INTERVAL_DURATION_IN_MS,
      );
    }

    return () => clearInterval(archiveFetchIntervalRef.current);
  }, [isArchiving]);

  const [isDownloading, setIsDownloading] = React.useState(false);

  const firstDownloadableFile = files[0];

  return (
    <Popover
      disabled={isDownloading}
      trigger={
        <div className="button" contentEditable={false}>
          Download all
          <Icon name="outline-cheveron-down" />
        </div>
      }
    >
      <div className="grid gap-2">
        {isArchiving ? (
          <Button contentEditable={false} disabled>
            <LoadingSpinner />
            Zipping files...
          </Button>
        ) : files.length === 1 && firstDownloadableFile ? (
          <NavigationButton
            contentEditable={false}
            href={firstDownloadableFile.url}
            download={firstDownloadableFile.downloadFileName}
            target="_blank"
            rel="noopener noreferrer"
          >
            Download file
          </NavigationButton>
        ) : (
          <Button
            contentEditable={false}
            disabled={isDownloading}
            onClick={asyncVoid(async () => {
              setIsDownloading(true);
              try {
                const archive = await downloadInfo.getFolderArchive(folderId);
                if (!archive.url) setIsArchiving(true);
                else window.location.href = archive.url;
              } catch (e) {
                assertResponseError(e);
                showAlert(e.message, "error");
              }
              setIsDownloading(false);
            })}
          >
            Download as ZIP
          </Button>
        )}
        <Button
          contentEditable={false}
          disabled={isDownloading}
          onClick={asyncVoid(async () => {
            setIsDownloading(true);
            try {
              const fileDownloadInfos = await downloadInfo.getDownloadUrlsForFiles(files.map((f) => f.id));
              if (fileDownloadInfos.length === 0) return;
              Dropbox.save({ files: fileDownloadInfos });
            } catch (e) {
              assertResponseError(e);
              showAlert(e.message, "error");
            } finally {
              setIsDownloading(false);
            }
          })}
        >
          <Icon name="dropbox" />
          Save to Dropbox
        </Button>
      </div>
    </Popover>
  );
};
