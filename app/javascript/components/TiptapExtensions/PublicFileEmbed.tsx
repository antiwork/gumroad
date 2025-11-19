import { Node as TiptapNode } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";

import FileUtils, { FILE_TYPE_EXTENSIONS_MAP } from "$app/utils/file";

import { AudioPlayer } from "$app/components/AudioPlayer";
import { Button } from "$app/components/Button";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { usePublicFilesSettings } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { MenuItem } from "$app/components/RichTextEditor";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";

const NodeView = ({ editor, node }: NodeViewProps) => {
  const uid = React.useId();
  const { files, updateFile, cancelUpload } = usePublicFilesSettings();
  const id = String(node.attrs.id);
  const file = files.find((file) => file.id === id);
  const [expanded, setExpanded] = React.useState(false);
  const [showAudioPlayer, setShowAudioPlayer] = React.useState(false);
  const isUploading = file?.status?.type === "unsaved" && file.status.uploadStatus.type === "uploading";
  const uploadProgress =
    file?.status?.type === "unsaved" && file.status.uploadStatus.type === "uploading"
      ? file.status.uploadStatus.progress
      : null;
  const selected = editor.state.selection instanceof NodeSelection && editor.state.selection.node === node;

  if (!file) return null;

  return (
    <NodeViewWrapper contentEditable={false}>
      <div className={cx("embed", { selected })}>
        {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
        <div className="content">
          <FileRowContent
            extension={file.extension}
            name={file.name.trim() || "Untitled"}
            externalLinkUrl={null}
            isUploading={isUploading}
            hideIcon={false}
            details={
              <>
                {file.extension ? <li>{file.extension}</li> : null}

                <li>
                  {isUploading
                    ? `${((uploadProgress?.percent ?? 0) * 100).toFixed(0)}% of ${FileUtils.getFullFileSizeString(
                        file.file_size ?? 0,
                      )}`
                    : FileUtils.getFullFileSizeString(file.file_size ?? 0)}
                </li>
              </>
            }
          />
        </div>
        <div className="actions">
          {isUploading ? (
            <Button color="danger" onClick={() => cancelUpload?.(id)}>
              Cancel
            </Button>
          ) : null}
          {editor.isEditable && !isUploading ? (
            <Button onClick={() => setExpanded(!expanded)} aria-label={expanded ? "Close drawer" : "Edit"}>
              <Icon name={expanded ? "outline-cheveron-up" : "outline-cheveron-down"} />
            </Button>
          ) : null}
          {FileUtils.isAudioExtension(file.extension) ? (
            <Button color="primary" onClick={() => setShowAudioPlayer(!showAudioPlayer)}>
              {showAudioPlayer ? "Close" : "Play"}
            </Button>
          ) : null}
        </div>
        {FileUtils.isAudioExtension(file.extension) && showAudioPlayer && file.url ? (
          <AudioPlayer src={file.url} />
        ) : null}
        {expanded ? (
          <div className="drawer flex flex-col gap-4">
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-name`}>Name</label>
              </legend>
              <input
                type="text"
                id={`${uid}-name`}
                value={file.name}
                onChange={(e) => updateFile?.(id, { name: e.target.value })}
                placeholder="Enter file name"
              />
            </fieldset>
          </div>
        ) : null}
      </div>
    </NodeViewWrapper>
  );
};

export const PublicFileEmbed = TiptapNode.create({
  name: "publicFileEmbed",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes: () => ({
    id: { default: null },
  }),
  parseHTML: () => [{ tag: "public-file-embed" }],
  renderHTML: ({ HTMLAttributes }) => ["public-file-embed", HTMLAttributes],

  addNodeView() {
    return ReactNodeViewRenderer(NodeView);
  },

  menuItem: (editor) => {
    const inputRef = React.useRef<HTMLInputElement | null>(null);
    const { onUpload, audioPreviewsEnabled } = usePublicFilesSettings();
    if (!audioPreviewsEnabled) return null;
    return (
      <>
        <MenuItem
          name="Insert audio"
          icon="music-note-beamed"
          active={editor.isActive("public-file-embed")}
          onClick={() => inputRef.current?.click()}
        />
        <input
          ref={inputRef}
          type="file"
          accept={FILE_TYPE_EXTENSIONS_MAP.audio.map((ext) => `.${ext.toLowerCase()}`).join(",")}
          onChange={(e) => {
            const files = [...(e.target.files || [])];
            if (!files.length) return;
            const file = files[0];
            if (!file) return;
            onUpload?.({ file });
            e.target.value = "";
          }}
        />
      </>
    );
  },
});
