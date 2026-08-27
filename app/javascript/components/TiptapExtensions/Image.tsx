import { Image as ImageIcon } from "@boxicons/react";
import { Node as TiptapNode } from "@tiptap/core";
import { Node as ProseMirrorNode } from "@tiptap/pm/model";
import { Transaction } from "@tiptap/pm/state";
import { EditorView } from "@tiptap/pm/view";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import typia from "typia";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import FileUtils from "$app/utils/file";
import { isLikelyImageFile, prepareImageForUpload, heicDecodingLikely } from "$app/utils/prepareImageForUpload";
import {
  canResetFileInputAfterSnapshot,
  fileListMatchesPickedFiles,
  snapshotPickedFiles,
} from "$app/utils/snapshotPickedFile";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import {
  getInsertAtFromSelection,
  ImageUploadSettings,
  MenuItem,
  useImageUploadSettings,
} from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

const forEachImage = (
  view: EditorView,
  src: string,
  cb: (descendant: ProseMirrorNode, nodePos: number) => void,
): void =>
  view.state.doc.descendants((descendant, nodePos) => {
    if (descendant.type.name === "image" && descendant.attrs.src === src) cb(descendant, nodePos);
  });

const setImageSrcInView = (view: EditorView, src: string, newSrc: string) =>
  forEachImage(view, src, (_, nodePos) => {
    view.dispatch(view.state.tr.setNodeMarkup(nodePos, undefined, { src: newSrc }));
  });

const deleteImageInView = (view: EditorView, src: string) =>
  forEachImage(view, src, (descendant, nodePos) => {
    view.dispatch(view.state.tr.deleteRange(nodePos, nodePos + descendant.nodeSize));
  });

// Keep insertAt valid while decode/resize runs. Callers may already map through
// file snapshotting; this covers the slower prepareImageForUpload window.
// One shared dispatch hook per view: overlapping uploadImages must not restore
// a captured handler and rip out a still-running tracker.
type PosMapper = (tr: Transaction) => void;
type DispatchHook = { original: EditorView["dispatch"]; mappers: Set<PosMapper> };
const dispatchHooks = new WeakMap<EditorView, DispatchHook>();

const trackMappedPos = (view: EditorView, start: number) => {
  let pos = start;
  const mapper: PosMapper = (tr) => {
    pos = tr.mapping.map(pos);
  };

  let hook = dispatchHooks.get(view);
  if (!hook) {
    const original = view.dispatch.bind(view);
    const mappers = new Set<PosMapper>();
    view.dispatch = (tr: Transaction) => {
      if (tr.docChanged) {
        for (const map of mappers) map(tr);
      }
      original(tr);
    };
    hook = { original, mappers };
    dispatchHooks.set(view, hook);
  }
  hook.mappers.add(mapper);

  return {
    get: () => pos,
    stop: () => {
      const current = dispatchHooks.get(view);
      if (!current) return;
      current.mappers.delete(mapper);
      if (current.mappers.size === 0) {
        view.dispatch = current.original;
        dispatchHooks.delete(view);
      }
    },
  };
};

export const uploadImages = ({
  view,
  files,
  imageSettings,
  insertAt = getInsertAtFromSelection(view.state.selection),
}: {
  view: EditorView;
  files: File[];
  insertAt?: number | undefined;
  imageSettings: ImageUploadSettings | null;
}) => {
  if (!imageSettings || !files.length) return Promise.resolve();

  const { maxFileSize } = imageSettings;

  return (async () => {
    const mapped = trackMappedPos(view, insertAt);
    const prepared: File[] = [];
    try {
      for (const file of files) {
        try {
          const next = isLikelyImageFile(file)
            ? await prepareImageForUpload(file, maxFileSize ? { maxBytes: maxFileSize } : undefined)
            : file;
          // Check the post-prep name so HEIC/AVIF that re-encoded to JPEG pass, while
          // SVG/ICO that skipped prep still fail the editor's extension allow-list.
          if (!FileUtils.isFileNameExtensionAllowed(next.name, imageSettings.allowedExtensions)) {
            showAlert("Invalid file type.", "error");
            continue;
          }
          if (maxFileSize && next.size > maxFileSize) {
            showAlert(`File is too large (max allowed size is ${FileUtils.getReadableFileSize(maxFileSize)})`, "error");
            continue;
          }
          prepared.push(next);
        } catch {
          showAlert("Could not process that image.", "error");
        }
      }
      if (!prepared.length) return;

      const imageSchema = assertDefined(view.state.schema.nodes.image, "Image node type missing");
      const pos = mapped.get();

      // We reverse the files so their order in the editor is the same as the order they were selected
      const filesWithUrls = [...prepared].reverse().map((file) => {
        const src = URL.createObjectURL(file);
        const node = imageSchema.create({ src, uploading: true });
        view.dispatch(view.state.tr.insert(pos, node));
        return { file, src };
      });

      await Promise.all(
        filesWithUrls.map(
          ({ file, src }) =>
            imageSettings.onUpload(file, src)?.then(
              (newSrc) => setImageSrcInView(view, src, newSrc),
              () => deleteImageInView(view, src),
            ) ?? Promise.resolve(),
        ),
      );
    } finally {
      mapped.stop();
    }
  })();
};

const ImageNodeView = ({ node, editor, getPos }: NodeViewProps) => {
  const [hasFocus, setHasFocus] = React.useState(false);
  const nodeRef = React.useRef(null);

  const { attrs } = node;

  const handleImageClick = React.useCallback(() => {
    if (editor.isEditable) {
      setHasFocus(true);
      editor.commands.setNodeSelection(getPos());
    }
  }, [editor, getPos]);

  useOnOutsideClick([nodeRef], () => setHasFocus(false));

  const [isImageLoaded, setIsImageLoaded] = React.useState(false);
  const isUploading = editor.isEditable && !!attrs.uploading && isImageLoaded;
  const imageMarkup = (
    <img
      {...{ ...attrs, uploading: undefined }}
      className={classNames(
        "selection:bg-muted",
        editor.isEditable && "cursor-pointer",
        hasFocus && "outline-2 outline-accent",
      )}
      onLoad={() => setIsImageLoaded(true)}
      onClick={handleImageClick}
      data-drag-handle
      contentEditable={false}
    />
  );

  return (
    <NodeViewWrapper>
      <figure ref={nodeRef} style={isUploading ? { position: "relative" } : undefined}>
        {attrs.link ? (
          <a href={typia.assert<string>(attrs.link)} target="_blank" rel="noopener noreferrer nofollow">
            {imageMarkup}
          </a>
        ) : (
          imageMarkup
        )}
        {hasFocus || node.content.size > 0 ? (
          <NodeViewContent as="p" className="figcaption" data-placeholder="Add a caption" />
        ) : null}

        {isUploading ? (
          <div
            style={{
              position: "absolute",
              top: 0,
              left: 0,
              background: "rgb(var(--color) / var(--gray-3))",
              width: "100%",
              height: "100%",
            }}
          >
            <div
              style={{
                position: "absolute",
                top: "50%",
                left: "50%",
                transform: "translate(-50%, -50%)",
              }}
            >
              <LoadingSpinner className="size-16" />
            </div>
          </div>
        ) : null}
      </figure>
    </NodeViewWrapper>
  );
};

export const Image = TiptapNode.create({
  name: "image",
  inline: false,
  group: "block",
  content: "inline*",
  draggable: true,
  // fixes bug, see: https://github.com/gumroad/web/pull/24134#issuecomment-1247356616
  isolating: true,
  addAttributes: () => ({
    src: { default: null },
    link: { default: null },
    uploading: { default: undefined },
  }),
  parseHTML: () => [
    {
      tag: "figure",
      getAttrs: (node) => {
        if (!(node instanceof Node)) return false;
        const childNode = node.childNodes[0];
        if (childNode instanceof HTMLAnchorElement) {
          const img = childNode.childNodes[0];
          if (!(img instanceof HTMLImageElement)) return false;
          return { src: img.src, link: childNode.href };
        } else if (childNode instanceof HTMLImageElement) {
          return { src: childNode.src };
        }

        return false;
      },
      contentElement: (node) => {
        const captionNode = node.childNodes[1];
        if (!(captionNode instanceof HTMLParagraphElement && captionNode.classList.contains("figcaption")))
          return document.createElement("p");

        return captionNode;
      },
    },
  ],
  renderHTML: ({ HTMLAttributes }) => {
    if (typeof HTMLAttributes.link === "string") {
      return [
        "figure",
        [
          "a",
          {
            href: HTMLAttributes.link,
            target: "_blank",
            rel: "noopener noreferrer nofollow",
          },
          ["img", HTMLAttributes],
        ],
        ["p", { class: "figcaption" }, 0],
      ];
    }
    return ["figure", ["img", HTMLAttributes], ["p", { class: "figcaption" }, 0]];
  },

  addNodeView() {
    return ReactNodeViewRenderer(ImageNodeView);
  },

  menuItem: (editor) => {
    const inputRef = React.useRef<HTMLInputElement | null>(null);
    const snapshotInFlight = React.useRef(false);
    const imageSettings = useImageUploadSettings();
    if (!imageSettings) return null;
    return (
      <>
        <MenuItem
          name="Insert image"
          icon={<ImageIcon className="size-5" />}
          active={editor.isActive("image")}
          onClick={() => {
            if (snapshotInFlight.current || inputRef.current?.disabled) return;
            inputRef.current?.click();
          }}
        />
        <input
          className="sr-only"
          ref={inputRef}
          multiple
          type="file"
          accept={[
            ...imageSettings.allowedExtensions.map((ext) => `.${ext}`),
            "image/avif",
            ...(heicDecodingLikely() ? [".heic", ".heif"] : []),
          ].join(",")}
          onChange={(e) => {
            const input = e.target;
            if (snapshotInFlight.current || !input.files) return;
            const picked = [...input.files];
            if (!picked.length) return;
            // Map the caret through edits that land while we read the file.
            let insertAt = getInsertAtFromSelection(editor.view.state.selection);
            const mapInsertAt = ({ transaction }: { transaction: { mapping: { map: (pos: number) => number } } }) => {
              insertAt = transaction.mapping.map(insertAt);
            };
            editor.on("transaction", mapInsertAt);
            snapshotInFlight.current = true;
            input.disabled = true;
            void snapshotPickedFiles(picked)
              .then(async (files) => {
                const uploads = uploadImages({ view: editor.view, files, imageSettings, insertAt });
                const snapshotted =
                  fileListMatchesPickedFiles(input.files, picked) && canResetFileInputAfterSnapshot(picked, files);
                if (snapshotted) input.value = "";
                if (!snapshotted) {
                  await uploads;
                  if (fileListMatchesPickedFiles(input.files, picked)) input.value = "";
                }
              })
              .catch((error: unknown) => {
                showAlert(error instanceof Error ? error.message : "Could not read the selected file.", "error");
                if (fileListMatchesPickedFiles(input.files, picked)) input.value = "";
              })
              .finally(() => {
                editor.off("transaction", mapInsertAt);
                snapshotInFlight.current = false;
                input.disabled = false;
              });
          }}
        />
      </>
    );
  },
});
