import { CommandProps, JSONContent } from "@tiptap/core";

export const createInsertCommand =
  (type: string) =>
  (options: JSONContent["attrs"]) =>
  ({ commands, state }: CommandProps) => {
    const { $head, empty } = state.selection;
    let { from } = state.selection;

    // If caret is on an empty line, insert content before it to avoid an empty row before embeds
    if ((empty && $head.parent.content.size === 0) || $head.parentOffset === 0) from -= 1;
    const content: JSONContent = { type };
    if (options) content.attrs = options;
    return commands.insertContentAt(from, content);
  };
