import { Node as TiptapNode } from "@tiptap/core";
import { ReactNodeViewRenderer } from "@tiptap/react";

import { TextInputNodeView } from "$app/components/TiptapExtensions/TextInputNodeView";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    shortAnswer: {
      insertShortAnswer: (options: Record<string, never>) => ReturnType;
    };
  }
}

export const ShortAnswer = TiptapNode.create({
  name: "shortAnswer",
  selectable: true,
  draggable: true,
  atom: true,
  group: "block",
  parseHTML: () => [{ tag: "short-answer" }],
  renderHTML: ({ HTMLAttributes }) => ["short-answer", HTMLAttributes],
  addAttributes: () => ({ label: { default: "" }, id: { default: null } }),
  addNodeView() {
    return ReactNodeViewRenderer(TextInputNodeView);
  },
  addCommands() {
    return {
      insertShortAnswer: createInsertCommand("shortAnswer"),
    };
  },
});
