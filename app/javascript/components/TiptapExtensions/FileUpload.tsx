import { NodeViewProps, Node as TiptapNode } from "@tiptap/core";
import { NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { FileInput } from "$app/components/Download/CustomField/FileInput";
import { Icon } from "$app/components/Icons";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";

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
    {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
    {editor.isEditable ? (
      <fieldset className="flex items-center justify-center rounded border border-border bg-background p-6">
        <Button color="primary">
          <Icon name="upload-fill" />
          Upload files
        </Button>
      </fieldset>
    ) : (
      <FileInput customFieldId={cast<string>(node.attrs.id)} />
    )}
  </NodeViewWrapper>
);
