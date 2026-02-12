import * as React from "react";
import { NodeViewWrapper, ReactNodeViewRenderer, NodeViewProps } from "@tiptap/react";
import { Image as BaseImage } from "$app/components/TiptapExtensions/Image";
import { RemoveButton } from "$app/components/RemoveButton";

const RemovableImageView = (props: NodeViewProps) => {
  const { node, editor, getPos } = props;
  const src = node.attrs.src as string | undefined;

  const remove = () => {
    const pos = typeof getPos === "function" ? getPos() : null;
    if (pos == null) return;

    editor
      .chain()
      .focus()
      .command(({ tr }) => {
        tr.delete(pos, pos + node.nodeSize);
        return true;
      })
      .run();
  };

  return (
    <NodeViewWrapper
      as="span"
      className="tiptap-image-wrapper"
      style={{ position: "relative", display: "inline-block" }}
    >
      <img src={src} />

      <RemoveButton
        aria-label="Remove image"
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          remove();
        }}
        style={{
          position: "absolute",
          top: 0,
          right: 0,
          transform: "translate(50%, -50%)",
          zIndex: 2,
        }}
      />
    </NodeViewWrapper>
  );
};

export const RemovableImage = BaseImage.extend({
  name: BaseImage.name,
  addNodeView() {
    return ReactNodeViewRenderer(RemovableImageView);
  },
});
