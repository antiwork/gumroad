import { Node as TiptapNode } from "@tiptap/core";
import { ReactNodeViewRenderer } from "@tiptap/react";

import { TextInputNodeView } from "$app/components/TiptapExtensions/TextInputNodeView";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    longAnswer: {
      insertLongAnswer: (options: Record<string, never>) => ReturnType;
    };
  }
}

export const LongAnswer = TiptapNode.create({
  name: "longAnswer",
  selectable: true,
  draggable: true,
  atom: true,
  group: "block",
  parseHTML: () => [{ tag: "long-answer" }],
  renderHTML: ({ HTMLAttributes }) => ["long-answer", HTMLAttributes],
  addAttributes: () => ({ label: { default: "" }, id: { default: null } }),
  addNodeView() {
    return ReactNodeViewRenderer(TextInputNodeView);
  },
  addCommands() {
    return {
      insertLongAnswer: createInsertCommand("longAnswer"),
    };
  },
});
