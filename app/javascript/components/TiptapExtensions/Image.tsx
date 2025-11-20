import { Node as TiptapNode } from "@tiptap/core";
import { Node as ProseMirrorNode } from "@tiptap/pm/model";
import { EditorView } from "@tiptap/pm/view";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertDefined } from "$app/utils/assert";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import {
  getInsertAtFromSelection,
  ImageUploadSettings,
  MenuItem,
  useImageUploadSettings,
} from "$app/components/RichTextEditor";
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

export const uploadImages = ({
  view,
  files,
  imageSettings,
}: {
  view: EditorView;
  files: File[];
  insertAt?: number | undefined;
  imageSettings: ImageUploadSettings | null;
}) => {
  if (!imageSettings || !files.length) return;

  const insertAt = getInsertAtFromSelection(view.state.selection);
  const imageSchema = assertDefined(view.state.schema.nodes.image, "Image node type missing");

  // We reverse the files so their order in the editor is the same as the order they were selected
  const filesWithUrls = [...files].reverse().map((file) => {
    const src = URL.createObjectURL(file);
    const node = imageSchema.create({ src, uploading: true });
    view.dispatch(view.state.tr.insert(insertAt, node));
    return { file, src };
  });

  for (const { file, src } of filesWithUrls) {
    imageSettings.onUpload(file, src)?.then(
      (newSrc) => setImageSrcInView(view, src, newSrc),
      () => deleteImageInView(view, src),
    );
  }
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
  const isUploading = editor.isEditable && cast(attrs.uploading) && isImageLoaded;
  const imageMarkup = (
    <img
      {...{ ...attrs, uploading: undefined }}
      onLoad={() => setIsImageLoaded(true)}
      onClick={handleImageClick}
      data-drag-handle
      contentEditable={false}
    />
  );

  return (
    <NodeViewWrapper>
      <figure
        ref={nodeRef}
        data-has-focus={hasFocus || undefined}
        style={isUploading ? { position: "relative" } : undefined}
      >
        {attrs.link ? (
          <a href={cast(attrs.link)} target="_blank" rel="noopener noreferrer nofollow">
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
    const imageSettings = useImageUploadSettings();
    if (!imageSettings) return null;
    return (
      <>
        <MenuItem
          name="Insert image"
          icon="image"
          active={editor.isActive("image")}
          onClick={() => inputRef.current?.click()}
        />
        <input
          ref={inputRef}
          multiple
          type="file"
          accept={imageSettings.allowedExtensions.map((ext) => `.${ext}`).join(",")}
          onChange={(e) => {
            const files = [...(e.target.files || [])];
            if (!files.length) return;
            uploadImages({ view: editor.view, files, imageSettings });
            e.target.value = "";
          }}
        />
      </>
    );
  },
});
