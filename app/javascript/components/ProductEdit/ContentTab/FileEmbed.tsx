import { DirectUpload } from "@rails/activestorage";
import { Editor, findChildren, Node as TiptapNode } from "@tiptap/core";
import { DOMParser as ProseMirrorDOMParser, DOMSerializer } from "@tiptap/pm/model";
import { NodeSelection, Plugin } from "@tiptap/pm/state";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { cancelDropboxFileUpload } from "$app/data/dropbox_upload";
import { assertDefined } from "$app/utils/assert";
import FileUtils from "$app/utils/file";
import { createJWPlayer } from "$app/utils/jwPlayer";
import { getMimeType } from "$app/utils/mimetypes";
import { summarizeUploadProgress } from "$app/utils/summarizeUploadProgress";

import { AudioPlayer } from "$app/components/AudioPlayer";
import { Button, NavigationButton } from "$app/components/Button";
import { useEvaporateUploader } from "$app/components/EvaporateUploader";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { PlayVideoIcon } from "$app/components/PlayVideoIcon";
import { Popover } from "$app/components/Popover";
import { FileEntry, useProductEditContext } from "$app/components/ProductEdit/state";
import { Progress } from "$app/components/Progress";
import { useS3UploadConfig } from "$app/components/S3UploadConfig";
import { Separator } from "$app/components/Separator";
import { showAlert } from "$app/components/server-components/Alert";
import { SubtitleList } from "$app/components/SubtitleList";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { SubtitleUploadBox } from "$app/components/SubtitleUploadBox";
import { FileEmbedGroup, titleWithFallback } from "$app/components/TiptapExtensions/FileEmbedGroup";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import Placeholder from "$app/components/ui/Placeholder";
import { WithTooltip } from "$app/components/WithTooltip";

export const getDownloadUrl = (productId: string, file: FileEntry) =>
  file.extension === "URL" || file.status.type === "removed"
    ? null
    : file.status.type === "unsaved"
      ? file.status.url
      : Routes.download_product_files_path(productId, { product_file_ids: [file.id] });

export const getDraggedFileEmbed = (editor: Editor) => {
  const draggedNode = editor.view.dragging?.slice.content.firstChild;
  return draggedNode?.type.name === FileEmbed.name ? draggedNode : null;
};

const FileEmbedNodeView = ({ node, editor, getPos, updateAttributes }: NodeViewProps) => {
  const { id, product, updateProduct } = useProductEditContext();
  const uid = React.useId();
  const ref = React.useRef<HTMLDivElement>(null);
  const [expanded, setExpanded] = React.useState(false);
  const [isDropZone, setIsDropZone] = React.useState(false);
  const [loadingVideo, setLoadingVideo] = React.useState(false);
  const [showingVideoPlayer, setShowingVideoPlayer] = React.useState(false);
  const [showingAudioDrawer, setShowingAudioDrawer] = React.useState(false);
  const uploader = assertDefined(useEvaporateUploader());
  const s3UploadConfig = useS3UploadConfig();

  const file = product.files.find((file) => file.id === node.attrs.id);
  const downloadUrl = file && getDownloadUrl(id, file);

  const playerRef = React.useRef<jwplayer.JWPlayer | null>(null);
  const uploadedSubtitleFiles =
    file?.subtitle_files.filter(
      (subtitle) => subtitle.status.type !== "unsaved" || subtitle.status.uploadStatus.type === "uploaded",
    ) ?? [];
  React.useEffect(() => {
    if (!downloadUrl || !showingVideoPlayer) return;
    void createJWPlayer(`${uid}-video`, {
      playlist: [
        {
          sources: [{ file: downloadUrl, type: file.extension?.toLowerCase() }],
          tracks: uploadedSubtitleFiles.map((subtitleFile) => ({
            file: subtitleFile.signed_url,
            label: subtitleFile.language,
            kind: "captions",
          })),
        },
      ],
    }).then((player) => {
      const play = (playerRef.current?.getState() ?? "playing") === "playing";
      const position = playerRef.current?.getPosition();
      playerRef.current = player;
      player
        .on("ready", () => {
          if (play) playerRef.current?.play();
          if (position) playerRef.current?.seek(position);
        })
        .on("complete", () => {
          setShowingVideoPlayer(false);
          playerRef.current = null;
        });
    });
  }, [showingVideoPlayer, JSON.stringify(uploadedSubtitleFiles.map((subtitle) => subtitle.url))]);

  const generateThumbnail = () => {
    if (!downloadUrl || file.thumbnail) return;

    setLoadingVideo(true);

    const video = document.createElement("video");
    video.src = downloadUrl;
    video.setAttribute("crossorigin", "anonymous");
    // Delay to work around a bug in Safari which otherwise captures a black/empty thumbnail
    video.onloadedmetadata = () => setTimeout(() => (video.currentTime = 1), 100);
    video.onseeked = () => {
      const canvas = document.createElement("canvas");
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      const ctx = assertDefined(canvas.getContext("2d"));
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      canvas.toBlob(
        (blob) => {
          setLoadingVideo(false);
          if (blob) uploadThumbnail(new File([blob], "thumbnail.jpg"));
          video.remove();
          canvas.remove();
        },
        "image/jpeg",
        0.5,
      );
    };
  };
  // not using the built-in deleteNode here as that one does not delete empty parent nodes
  const deleteNode = () => {
    queueMicrotask(() => {
      const pos = getPos();
      // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Tiptap types are wrong
      if (pos == null) return;
      const tr = editor.state.tr;
      const mappedPos = tr.mapping.map(pos);
      tr.deleteRange(mappedPos, mappedPos + node.nodeSize);
      editor.view.dispatch(tr);
    });
  };
  const fileExists = file && file.status.type !== "removed";
  React.useEffect(() => {
    if (file?.status.type === "unsaved" && file.status.uploadStatus.type === "uploading") generateThumbnail();
  }, [file?.status.type]);

  const pos = getPos();
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Tiptap types are wrong
  const parentNode = pos == null ? null : editor.state.doc.resolve(pos).parent;
  // The `selected` prop from Tiptap also returns true when the parent folder is selected,
  // but we only want to show the outline when this exact node is selected
  const selected = editor.state.selection instanceof NodeSelection && editor.state.selection.node === node;
  const fileEmbedGroups = React.useMemo(
    () =>
      findChildren(editor.state.doc, ({ type }) => type.name === FileEmbedGroup.name).flatMap(({ node: groupNode }) =>
        groupNode === parentNode
          ? []
          : [{ uid: cast<string>(groupNode.attrs.uid), name: titleWithFallback(groupNode.attrs.name) }],
      ),
    [selected],
  );

  if (!fileExists) return;
  const updateFile = (data: Partial<FileEntry>) =>
    updateProduct((product) => {
      const existing = product.files.find((existing) => existing.id === file.id);
      if (existing) Object.assign(existing, data);
    });
  const isComplete = !(
    (file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading") ||
    (file.status.type === "dropbox" && file.status.uploadState === "in_progress")
  );
  const uploadProgress =
    file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading"
      ? file.status.uploadStatus.progress
      : null;
  const onCancel = () => {
    deleteNode();
    uploader.cancelUpload(`file_${file.id}`);
    if (file.status.type === "dropbox") void cancelDropboxFileUpload(file.id);
  };

  const setDragOver = (value: boolean) => {
    // Prevent dropcursor showing up around file embed rather than inside
    document.querySelector(".product-content .drop-cursor")?.classList.toggle("hidden", value);
    setIsDropZone(value);
  };

  const isInGroup = parentNode?.type.name === FileEmbedGroup.name;
  const shouldIgnoreFileGroupingAt = (clientY: number) => {
    if (!ref.current) return false;

    const threshold = 10;
    const { top, bottom } = ref.current.getBoundingClientRect();
    return clientY < top + threshold || clientY > bottom - threshold;
  };

  const uploadThumbnail = (thumbnail: File) => {
    if (thumbnail.size > 5 * 1024 * 1024)
      return showAlert(
        "Could not process your thumbnail, please upload an image with size smaller than 5 MB.",
        "error",
      );

    setLoadingVideo(true);
    const upload = new DirectUpload(thumbnail, Routes.rails_direct_uploads_path());
    upload.create((error, blob) => {
      if (error) return showAlert(error.message, "error");
      updateFile({
        thumbnail: {
          url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
          signed_id: blob.signed_id,
          status: { type: "unsaved" },
        },
      });
      setLoadingVideo(false);
    });
  };
  const onThumbnailSelected = (files: FileList | null) => {
    const thumbnail = files?.[0];
    if (thumbnail) uploadThumbnail(thumbnail);
  };
  const thumbnailInput = (
    <input type="file" accept=".jpg,.jpeg,.png,.gif" onChange={(e) => onThumbnailSelected(e.target.files)} />
  );

  const removeSubtitle = (url: string) =>
    updateFile({ subtitle_files: file.subtitle_files.filter((subtitle) => subtitle.url !== url) });
  const uploadSubtitles = (files: File[]) => {
    for (const subtitleFile of files) {
      const mimeType = getMimeType(subtitleFile.name);
      const extension = FileUtils.getFileExtension(subtitleFile.name).toUpperCase();
      const fileName = FileUtils.getFileNameWithoutExtension(subtitleFile.name);
      const fileSize = subtitleFile.size;
      const id = FileUtils.generateGuid();
      const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(id, subtitleFile.name);

      const subtitleEntry: SubtitleFile = {
        file_name: fileName,
        extension,
        language: "English",
        file_size: fileSize,
        url: fileUrl,
        signed_url: URL.createObjectURL(subtitleFile),
        status: { type: "unsaved", uploadStatus: { type: "uploading", progress: { percent: 0, bitrate: 0 } } },
      };

      updateFile({ subtitle_files: [...file.subtitle_files, subtitleEntry] });

      const status = uploader.scheduleUpload({
        cancellationKey: `subtitles_for_${file.id}__${subtitleEntry.url}`,
        name: s3key,
        file: subtitleFile,
        mimeType,
        onComplete: () => {
          subtitleEntry.status = { type: "unsaved", uploadStatus: { type: "uploaded" } };
          updateFile({});
        },
        onProgress: (progress) => {
          subtitleEntry.status = { type: "unsaved", uploadStatus: { type: "uploading", progress } };
          updateFile({});
        },
      });

      if (typeof status === "string") {
        // status contains error string if any, otherwise index of file in array
        showAlert(status, "error");
      }
    }
  };

  const folderAction = {
    item: () => (
      <>
        <Icon name="solid-folder-open" />
        <span>Move to folder...</span>
      </>
    ),
    menu: () => (
      <>
        {parentNode?.childCount === 1 ? null : (
          <div
            onClick={() => editor.commands.moveFileEmbedToGroup({ fileUid: cast(node.attrs.uid), groupUid: null })}
            role="menuitem"
          >
            <Icon name="folder-plus" />
            <span>New folder</span>
          </div>
        )}
        {fileEmbedGroups.map(({ uid, name }) => (
          <div
            key={uid}
            onClick={() => {
              editor.commands.moveFileEmbedToGroup({ fileUid: cast(node.attrs.uid), groupUid: uid });

              const fileName = product.files.find((file) => file.id === node.attrs.id)?.display_name;
              if (fileName) showAlert(`Moved "${fileName}" to "${name}".`, "success");
            }}
            role="menuitem"
          >
            <Icon name="solid-folder-open" />
            <span>{name || "Untitled"}</span>
          </div>
        ))}
      </>
    ),
  };

  return (
    <NodeViewWrapper
      ref={ref}
      onDragOver={(e: DragEvent) => {
        const draggedFileEmbed = getDraggedFileEmbed(editor);
        setDragOver(
          !isInGroup && !!draggedFileEmbed && draggedFileEmbed !== node && !shouldIgnoreFileGroupingAt(e.clientY),
        );
      }}
      onDragLeave={(e: DragEvent) => {
        // dragleave events are fired when moving the cursor between sub-elements
        const isMovedToChild =
          e.relatedTarget instanceof Element &&
          e.currentTarget instanceof Element &&
          e.currentTarget.contains(e.relatedTarget);
        if (!isMovedToChild) setDragOver(false);
      }}
      onDrop={() => {
        setDragOver(false);
        const dragged = getDraggedFileEmbed(editor);
        if (!isDropZone || !dragged) return;
        const pos = getPos();
        const doc = editor.state.doc;
        const range = doc.resolve(pos).blockRange(doc.resolve(pos + node.nodeSize));
        if (!range) return;
        const targetNode = assertDefined(editor.view.state.schema.nodes[FileEmbed.name]).create(node.attrs);
        editor
          .chain()
          .command(({ tr }) => {
            tr.deleteSelection();
            tr.delete(tr.mapping.map(pos), tr.mapping.map(pos + node.nodeSize));
            return true;
          })
          .insertFileEmbedGroup({
            content: [targetNode, dragged],
            pos: editor.state.tr.doc.resolve(editor.state.tr.mapping.map(pos)).pos,
          })
          .run();
      }}
      className={cx({ "file-dropzone": isDropZone })}
      contentEditable={false}
    >
      <div className={cx("embed", { selected })} role={isInGroup ? "treeitem" : undefined}>
        {file.is_streamable && !node.attrs.collapsed ? (
          loadingVideo ? (
            <figure className="preview">
              <div style={{ position: "absolute", top: "50%", left: "50%", transform: "translate(-50%, -50%)" }}>
                <Progress width="4em" />
              </div>
            </figure>
          ) : file.thumbnail ? (
            showingVideoPlayer ? (
              <div className="preview">
                <div id={`${uid}-video`}></div>
              </div>
            ) : (
              <figure className="preview">
                <img
                  src={file.thumbnail.url}
                  style={{
                    position: "absolute",
                    height: "100%",
                    objectFit: "cover",
                    borderRadius: "var(--border-radius-1) var(--border-radius-1) 0 0",
                  }}
                />
                <button
                  className="link"
                  style={{
                    position: "absolute",
                    top: "50%",
                    left: "50%",
                    transform: "translate(-50%, -50%)",
                  }}
                  onClick={() => setShowingVideoPlayer(true)}
                  aria-label="Watch"
                >
                  <PlayVideoIcon />
                </button>
                <div style={{ position: "absolute", top: "var(--spacer-5)", right: "var(--spacer-5)" }}>
                  <WithTooltip tip="Replace thumbnail">
                    <label className="button primary" aria-label="Replace thumbnail">
                      {thumbnailInput}
                      <Icon name="upload-fill" />
                    </label>
                  </WithTooltip>
                </div>
              </figure>
            )
          ) : (
            <div className="preview">
              <Placeholder>
                <label className="button primary">
                  {thumbnailInput}
                  <Icon name="upload-fill" />
                  Upload a thumbnail
                </label>
                <div>
                  The thumbnail image is shown as a preview in the embedded video player. Your image should have a 16:9
                  aspect ratio, at least 1280x720px, and be in JPG, PNG, or GIF format.
                </div>
                <Separator>or</Separator>
                <div>
                  <Button onClick={generateThumbnail}>Generate a thumbnail</Button>
                </div>
              </Placeholder>
            </div>
          )
        ) : null}
        <NodeActionsMenu
          editor={editor}
          actions={!isInGroup || fileEmbedGroups.length > 0 || parentNode.childCount > 1 ? [folderAction] : []}
        />
        <div className="content">
          {file.is_streamable && node.attrs.collapsed ? (
            <label className="thumbnail" aria-label="Upload a thumbnail">
              {loadingVideo ? (
                <div style={{ placeSelf: "center" }}>
                  <Progress width="3em" />
                </div>
              ) : (
                <>
                  {file.thumbnail ? <img src={file.thumbnail.url} /> : null}
                  <Placeholder>
                    {thumbnailInput}
                    <Icon name="upload-fill" />
                  </Placeholder>
                </>
              )}
            </label>
          ) : null}
          <FileRowContent
            extension={file.extension}
            name={file.display_name}
            externalLinkUrl={file.url}
            isUploading={!isComplete}
            hideIcon={file.is_streamable}
            details={
              <>
                {file.extension ? <li>{file.extension}</li> : null}

                <li>
                  {file.extension === "URL"
                    ? file.url
                    : uploadProgress != null
                      ? summarizeUploadProgress(uploadProgress.percent, uploadProgress.bitrate, file.file_size ?? 0)
                      : FileUtils.getFullFileSizeString(file.file_size ?? 0)}
                </li>

                {file.is_streamable && isComplete ? (
                  <li>
                    <button className="link" onClick={() => setExpanded(!expanded)}>
                      {file.subtitle_files.length}{" "}
                      {file.subtitle_files.length === 1 ? "closed caption" : "closed captions"}
                    </button>
                  </li>
                ) : null}

                {isComplete && file.is_transcoding_in_progress ? <li>Transcoding in progress</li> : null}
              </>
            }
          />
        </div>

        <div className="actions">
          {downloadUrl && !file.stream_only ? (
            <NavigationButton
              href={downloadUrl}
              download={`${file.display_name}.${file.extension?.toLocaleLowerCase()}`}
            >
              Download
            </NavigationButton>
          ) : null}

          {file.is_streamable ? (
            <Popover
              trigger={
                <Button aria-label="Thumbnail view">
                  <Icon name={node.attrs.collapsed ? "arrows-expand" : "arrows-collapse"} />
                </Button>
              }
            >
              {(close) => (
                <div role="menu">
                  <div
                    role="menuitem"
                    onClick={() => {
                      updateAttributes({ collapsed: !node.attrs.collapsed });
                      close();
                    }}
                  >
                    <Icon name={node.attrs.collapsed ? "arrows-expand" : "arrows-collapse"} />
                    <span>{node.attrs.collapsed ? "Expand selected" : "Collapse selected"}</span>
                  </div>
                  <div
                    role="menuitem"
                    onClick={() => {
                      editor.commands.command(({ tr }) => {
                        const targetState = !node.attrs.collapsed;
                        tr.doc.descendants((node, pos) => {
                          if (node.type.name === FileEmbed.name && node.attrs.collapsed !== targetState) {
                            tr.setNodeMarkup(pos, null, {
                              ...node.attrs,
                              collapsed: targetState,
                            });
                          }
                        });
                        return true;
                      });
                      close();
                    }}
                  >
                    <Icon name={node.attrs.collapsed ? "arrows-expand" : "arrows-collapse"} />
                    <span>{node.attrs.collapsed ? "Expand all thumbnails" : "Collapse all thumbnails"}</span>
                  </div>
                </div>
              )}
            </Popover>
          ) : null}

          {!file.is_streamable || isComplete ? (
            <Button onClick={() => setExpanded(!expanded)} aria-label={expanded ? "Close drawer" : "Edit"}>
              <Icon name={expanded ? "outline-cheveron-up" : "outline-cheveron-down"} />
            </Button>
          ) : null}

          {!isComplete ? (
            <Button color="danger" outline onClick={onCancel} aria-label="Cancel">
              Cancel
            </Button>
          ) : null}

          {FileUtils.isAudioExtension(file.extension) ? (
            <Button color="primary" onClick={() => setShowingAudioDrawer(!showingAudioDrawer)}>
              {showingAudioDrawer ? "Close" : "Play"}
            </Button>
          ) : null}

          {file.is_streamable && node.attrs.collapsed ? (
            <Button
              color={showingVideoPlayer ? undefined : "primary"}
              onClick={() => setShowingVideoPlayer(!showingVideoPlayer)}
            >
              {showingVideoPlayer ? "Close" : "Play"}
            </Button>
          ) : null}
        </div>

        {file.description?.trim() && !expanded ? (
          <p style={{ marginLeft: "var(--spacer-2)", whiteSpace: "pre-wrap" }}>{file.description}</p>
        ) : null}

        {showingAudioDrawer && downloadUrl ? <AudioPlayer src={downloadUrl} /> : null}

        {expanded ? (
          <div className="drawer paragraphs">
            <fieldset>
              <legend>
                <label htmlFor={`${uid}name`}>Name</label>
              </legend>
              <input
                type="text"
                id={`${uid}name`}
                value={file.display_name}
                onChange={(evt) => updateFile({ display_name: evt.target.value })}
                placeholder="Name"
              />
            </fieldset>

            <fieldset>
              <legend>
                <label htmlFor={`${uid}description`}>Description</label>
              </legend>
              <textarea
                id={`${uid}description`}
                rows={3}
                maxLength={65_535}
                value={file.description ?? ""}
                onChange={(evt) => updateFile({ description: evt.target.value })}
                placeholder="Description"
              />
            </fieldset>

            {FileUtils.isDocumentExtension(file.extension) ? (
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}isbn`}>ISBN</label>
                </legend>
                <input
                  type="text"
                  id={`${uid}isbn`}
                  value={file.isbn ?? ""}
                  onChange={(evt) => updateFile({ isbn: evt.target.value })}
                  placeholder="ISBN"
                />
              </fieldset>
            ) : null}

            {file.is_pdf ? (
              <label>
                <input
                  type="checkbox"
                  role="switch"
                  checked={file.pdf_stamp_enabled}
                  onChange={(e) => updateFile({ pdf_stamp_enabled: e.target.checked })}
                />
                Stamp this PDF with buyer information
                <a href="/help/article/130-pdf-stamping" target="_blank" rel="noreferrer">
                  Learn more
                </a>
              </label>
            ) : null}

            {file.is_streamable ? (
              <>
                <fieldset>
                  <legend>Subtitles</legend>
                  <div className="paragraphs">
                    <SubtitleList
                      subtitleFiles={file.subtitle_files}
                      onRemoveSubtitle={removeSubtitle}
                      onCancelSubtitleUpload={removeSubtitle}
                      onChangeSubtitleLanguage={(url, language) =>
                        updateFile({
                          subtitle_files: file.subtitle_files.map((subtitle) =>
                            subtitle.url === url ? { ...subtitle, language } : subtitle,
                          ),
                        })
                      }
                    />
                    <SubtitleUploadBox onUploadFiles={uploadSubtitles} />
                  </div>
                </fieldset>
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={file.stream_only}
                    onChange={(e) => updateFile({ stream_only: e.target.checked })}
                  />
                  Disable file downloads (stream only)
                  <a href="/help/article/43-streaming-videos" target="_blank" rel="noreferrer">
                    Learn more
                  </a>
                </label>
              </>
            ) : null}
          </div>
        ) : null}
      </div>
      {isDropZone ? (
        <div className="backdrop">
          <div className="button primary">Create folder with 2 items</div>
        </div>
      ) : null}
    </NodeViewWrapper>
  );
};

export type FileEmbedConfig = { files: FileEntry[] };

export const FileEmbed = TiptapNode.create<{ getConfig?: () => FileEmbedConfig }>({
  name: "fileEmbed",
  group: "block",
  marks: "",
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes: () => ({ id: {}, uid: {}, url: { default: undefined }, collapsed: { default: false } }),
  parseHTML: () => [{ tag: "file-embed" }],
  renderHTML: ({ HTMLAttributes }) => ["file-embed", HTMLAttributes],

  addNodeView() {
    return ReactNodeViewRenderer(FileEmbedNodeView);
  },

  addProseMirrorPlugins() {
    const config = this.options.getConfig?.();
    if (!config) return [];
    const editor = this.editor;

    return [
      new Plugin({
        props: {
          transformCopied(slice) {
            const fragment = DOMSerializer.fromSchema(editor.schema).serializeFragment(slice.content);
            fragment.querySelectorAll("file-embed").forEach((node) => {
              const id = node.getAttribute("id");
              if (id) {
                const file = config.files.find((file) => file.id === id);
                if (file?.url) node.setAttribute("url", file.url);
              }
            });

            return ProseMirrorDOMParser.fromSchema(editor.schema).parseSlice(fragment);
          },
        },
      }),
    ];
  },
});
