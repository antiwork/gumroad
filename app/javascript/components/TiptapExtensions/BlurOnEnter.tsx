import { Extension } from "@tiptap/react";

export const BlurOnEnter = Extension.create({
  name: "keyboardShortcuts",
  addKeyboardShortcuts() {
    return {
      Enter: () => this.editor.commands.blur(),
    };
  },
});
