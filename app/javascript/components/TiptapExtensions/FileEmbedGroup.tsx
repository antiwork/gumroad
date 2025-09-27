import { Node as TiptapNode } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { getFolderArchiveDownloadUrl, getProductFileDownloadInfos } from "$app/data/products";
import { isTuple } from "$app/utils/array";
import GuidGenerator from "$app/utils/guid_generator";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { useRunOnce } from "$app/components/useRunOnce";

type FileEntry = {
  id: string;
  display_name: string;
  url: string | null;
  stream_only: boolean;
  pdf_stamp_enabled: boolean;
  is_streamable: boolean;
  file_size: number | null;
};
type FileGroupConfig = {
  productId: string;
  variantId: string | null;
  prepareDownload: () => Promise<void>;
  files: FileEntry[];
};
type FileEmbedGroupStorage = { lastCreatedUid: string | null };

export const titleWithFallback = (title: unknown) => (title ? String(title).trim() : "") || "Untitled";

// The actual archive size limit is 500 MB (524288000B)
const ARCHIVE_SIZE_LIMIT_IN_BYTES = 500000000;
const FileEmbedGroupNodeView = ({
  editor,
  node,
  updateAttributes,
  config,
  extension,
  selected,
}: NodeViewProps & { config: FileGroupConfig }) => {
  const [expanded, setExpanded] = React.useState(false);
  const [downloading, setDownloading] = React.useState(false);
  const [editing, setEditing] = React.useState(false);
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- https://tiptap.dev/guide/typescript#storage-types
  const storage = extension.storage as FileEmbedGroupStorage;
  const isNew = node.attrs.uid === storage.lastCreatedUid;
  const files: FileEntry[] = [];
  node.content.forEach((c) => {
    const file = config.files.find((file) => file.id === c.attrs.id);
    if (file) files.push(file);
  });
  const downloadableFiles = files.filter((file) => !!file.url && !file.stream_only);

  const folderTitle = titleWithFallback(node.attrs.name);
  const showDownloadButton =
    downloadableFiles.length > 0 &&
    !downloadableFiles.some((file) => file.pdf_stamp_enabled) &&
    downloadableFiles.reduce((total, file) => total + (file.file_size ?? 0), 0) < ARCHIVE_SIZE_LIMIT_IN_BYTES;
  const folderId = cast<string>(node.attrs.uid);

  const inputRef = React.useRef<HTMLInputElement>(null);
  useRunOnce(() => {
    if (isNew) {
      setExpanded(true);
      setEditing(true);
      storage.lastCreatedUid = null;
      // This causes a React error if called without a timeout
      setTimeout(() => inputRef.current?.focus(), 0);
    }
  });
  const uid = React.useId();
  const updateName = (name: string) => {
    updateAttributes({ ...node.attrs, name });
    setEditing(false);
  };

  const downloadArchive = async () => {
    try {
      const archive = await getFolderArchiveDownloadUrl(
        Routes.download_folder_archive_path(folderId, {
          product_id: config.productId,
          variant_id: config.variantId,
        }),
      );
      if (archive.url) {
        window.location.href = archive.url;
        setDownloading(false);
      } else setTimeout(() => void downloadArchive(), 5000);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setDownloading(false);
    }
  };

  const download = async () => {
    setDownloading(true);
    await config.prepareDownload();
    await downloadArchive();
  };

  const saveToDropbox = async () => {
    setDownloading(true);
    try {
      await config.prepareDownload();
      const fileDownloadInfos = await getProductFileDownloadInfos(
        Routes.download_product_files_path(config.productId, {
          product_file_ids: downloadableFiles.map((file) => file.id),
        }),
      );
      if (fileDownloadInfos.length > 0) Dropbox.save({ files: fileDownloadInfos });
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setDownloading(false);
  };

  return (
    <NodeViewWrapper contentEditable={false}>
      <div
        role="tree"
        onDragOver={() => {
          if (!expanded && editor.view.dragging?.slice.content.firstChild?.type.name === "fileEmbed") {
            setExpanded(true);
          }
        }}
      >
        <div role="treeitem" aria-expanded={expanded} className={cx({ selected })}>
          {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
          <div className="content" onClick={() => setExpanded(!expanded)} contentEditable={false}>
            <Icon name="solid-folder-open" className="type-icon" />
            {editing ? (
              <input
                type="text"
                ref={inputRef}
                defaultValue={node.attrs.name ? String(node.attrs.name) : ""}
                maxLength={120}
                placeholder="Folder name"
                onClick={(e) => e.stopPropagation()}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    updateName(e.currentTarget.value);
                  }
                }}
                onBlur={(e) => updateName(e.currentTarget.value)}
              />
            ) : (
              <div>
                <h4>{folderTitle}</h4>
              </div>
            )}
          </div>
          {showDownloadButton || editor.isEditable ? (
            <div className="actions">
              {showDownloadButton ? (
                <Popover
                  trigger={
                    <div className="button">
                      Download all
                      <Icon name="outline-cheveron-down" />
                    </div>
                  }
                >
                  <div className="grid gap-2">
                    {downloading ? (
                      <Button disabled>
                        <LoadingSpinner />
                        Zipping files...
                      </Button>
                    ) : isTuple(downloadableFiles, 1) ? (
                      <NavigationButton
                        href={downloadableFiles[0].url ?? undefined}
                        download={downloadableFiles[0].display_name}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        Download file
                      </NavigationButton>
                    ) : (
                      <Button onClick={() => void download()}>Download as ZIP</Button>
                    )}
                    <Button disabled={downloading} onClick={() => void saveToDropbox()}>
                      <Icon name="dropbox" />
                      Save to Dropbox
                    </Button>
                  </div>
                </Popover>
              ) : null}
              {editor.isEditable ? (
                <Button
                  aria-label="Edit"
                  onMouseDown={(e) => {
                    // NoOp if the user is already editing the name since it will
                    // automatically blur the input
                    if (editing) return;

                    // Prevent Tiptap selecting the node since it causes state mismatch errors
                    e.stopPropagation();

                    setEditing(true);
                    requestAnimationFrame(() => inputRef.current?.focus());
                  }}
                >
                  <Icon name={editing ? "outline-check" : "pencil"} />
                </Button>
              ) : null}
            </div>
          ) : null}
          {files.some((file) => file.is_streamable) ? (
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

export const FileEmbedGroup = TiptapNode.create<{ getConfig: () => FileGroupConfig }, FileEmbedGroupStorage>({
  name: "fileEmbedGroup",
  content: "fileEmbed+",
  group: "block",
  selectable: true,
  draggable: true,
  atom: true,
  addAttributes: () => ({
    uid: { isRequired: true },
    name: {
      default: null,
      // Explicitly parse to keep the value as String. Tiptap by default tries
      // to coerce the value automatically and converts `1.0` or `1` to a
      // number.
      parseHTML: (element) => element.getAttribute("name"),
    },
  }),
  parseHTML: () => [{ tag: "file-embed-group" }],
  renderHTML: ({ HTMLAttributes }) => ["file-embed-group", HTMLAttributes, 0],
  addStorage: () => ({ lastCreatedUid: null }),
  addNodeView() {
    const renderer = ReactNodeViewRenderer((props: NodeViewProps) =>
      FileEmbedGroupNodeView({
        ...props,
        config: this.options.getConfig(),
      }),
    );
    return (props) => {
      const view = renderer(props);
      if ("contentDOM" in view && view.contentDOM) view.contentDOM.style.display = "contents";
      return view;
    };
  },
  addCommands() {
    return {
      insertFileEmbedGroup:
        (options) =>
        ({ state, dispatch }) => {
          const transaction = state.tr;
          const { content, pos } = options;
          const uid = GuidGenerator.generate();
          const node = this.type.create({ uid }, content);
          this.storage.lastCreatedUid = uid;
          const insertAt = Math.min(Math.max(pos - 1, 0), transaction.doc.content.size);
          transaction.insert(insertAt, node);
          if (transaction.doc.nodeAt(insertAt))
            transaction.setSelection(NodeSelection.create(transaction.doc, insertAt));
          dispatch?.(transaction);
          return true;
        },
    };
  },
});
