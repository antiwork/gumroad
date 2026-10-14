import { EditorContent } from "@tiptap/react";
import * as React from "react";

import { useRichTextEditor } from "$app/components/RichTextEditor";

export const RichTextSection = ({ text }: { text: Record<string, unknown> }) => {
  // The page reveals this section the moment it loads; an editor created after that first paint
  // would start empty and push the sections below it down.
  const editor = useRichTextEditor({ initialValue: text, editable: false, immediatelyRender: true });
  return <EditorContent editor={editor} className="rich-text -mb-4" />;
};
