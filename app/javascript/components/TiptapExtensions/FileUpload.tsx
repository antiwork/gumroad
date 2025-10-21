import { NodeViewProps, Node as TiptapNode } from "@tiptap/core";
import { NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { FileInput } from "$app/components/Download/CustomField/FileInput";
import { Icon } from "$app/components/Icons";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import Placeholder from "$app/components/ui/Placeholder";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    fileUpload: {
      insertFileUpload: (options: Record<string, never>) => ReturnType;
    };
  }
}

export const FileUpload = TiptapNode.create({
  name: "fileUpload",
  selectable: false,
  draggable: true,
  atom: true,
  group: "block",
  parseHTML: () => [{ tag: "file-upload" }],
  renderHTML: ({ HTMLAttributes }) => ["file-upload", HTMLAttributes],
  addAttributes: () => ({ id: { default: null } }),
  addNodeView() {
    return ReactNodeViewRenderer(FileUploadNodeView);
  },
  addCommands() {
    return {
      insertFileUpload: createInsertCommand("fileUpload"),
    };
  },
});

const FileUploadNodeView = ({ editor, node }: NodeViewProps) => (
  <NodeViewWrapper data-drag-handle={editor.isEditable ? true : undefined}>
    {editor.isEditable ? (
      <Placeholder>
        <Button color="primary">
          <Icon name="upload-fill" />
          Upload files
        </Button>
      </Placeholder>
    ) : (
      <FileInput customFieldId={cast<string>(node.attrs.id)} />
    )}
  </NodeViewWrapper>
);
