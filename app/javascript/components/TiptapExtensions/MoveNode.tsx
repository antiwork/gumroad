import { Editor, findChildren } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { Extension } from "@tiptap/react";

import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEmbedGroup } from "$app/components/ProductEdit/ContentTab/FileEmbedGroup";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    moveNode: {
      moveNodeUp: () => ReturnType;
      moveNodeDown: () => ReturnType;
      moveFileEmbedToGroup: (options: { fileUid: string; groupUid: string | null }) => ReturnType;
    };
  }
}

export const MoveNode = Extension.create({
  name: "moveNode",
  addCommands() {
    return {
      moveNodeUp:
        () =>
        ({ dispatch, tr, state }) => {
          if (dispatch && state.selection instanceof NodeSelection) {
            const prevNode = state.selection.$from.nodeBefore;
            if (prevNode) {
              const prevPos = state.selection.from - prevNode.nodeSize;
              dispatch(tr.delete(state.selection.from, state.selection.to).insert(prevPos, state.selection.node));
              dispatch(tr.setSelection(NodeSelection.create(tr.doc, prevPos)));
            }
          }
          return true;
        },

      moveNodeDown:
        () =>
        ({ dispatch, tr, state, editor }) => {
          if (dispatch && state.selection instanceof NodeSelection) {
            const nextNode = state.selection.$to.nodeAfter;
            if (nextNode) {
              const nextPos = state.selection.from + nextNode.nodeSize;
              // Delete then insert in two steps in order to reuse the same React node and keep the popover open
              dispatch(tr.delete(state.selection.to, state.selection.to + nextNode.nodeSize));
              requestAnimationFrame(() => {
                editor.view.dispatch(editor.view.state.tr.insert(state.selection.from, nextNode));
                editor.view.dispatch(
                  editor.view.state.tr.setSelection(NodeSelection.create(editor.view.state.tr.doc, nextPos)),
                );
              });
            }
          }
          return true;
        },

      moveFileEmbedToGroup:
        (options) =>
        ({ state, dispatch, chain }) => {
          const fileNodes = findChildren(
            state.doc,
            (node) => node.type.name === FileEmbed.name && node.attrs.uid === options.fileUid,
          );
          if (fileNodes.length > 1) return false;

          const fileNodeWithPos = fileNodes[0];
          if (!fileNodeWithPos) return false;

          const { node: fileNode, pos } = fileNodeWithPos;
          const transaction = state.tr;

          // Remove the file embed from its current position
          transaction.deleteRange(pos, pos + fileNode.nodeSize);

          if (options.groupUid) {
            const groupNodes = findChildren(
              state.doc,
              (node) => node.type.name === FileEmbedGroup.name && node.attrs.uid === options.groupUid,
            );
            const groupNodeWithPos = groupNodes[0];
            if (!groupNodeWithPos) return false;
            const { node: groupNode, pos: groupNodePos } = groupNodeWithPos;

            // Insert the file embed at the end of the file embed group node
            const insertAt = transaction.doc.resolve(transaction.mapping.map(groupNodePos + groupNode.nodeSize - 1));
            dispatch?.(
              transaction
                .insert(insertAt.pos, fileNode)
                .setSelection(NodeSelection.create(transaction.doc, insertAt.pos))
                .scrollIntoView(),
            );
            return true;
          }
          // Create a new file embed group node and insert the file embed into it
          const insertAtResolvedPos = transaction.doc.resolve(transaction.mapping.map(pos));
          let insertAt = insertAtResolvedPos.pos;
          const parentNode = insertAtResolvedPos.parent;

          if (parentNode.type.name === FileEmbedGroup.name) {
            // If the parent node is a file embed group, insert the new group after the current group
            insertAt = transaction.mapping.map(pos + parentNode.nodeSize);
          }
          return chain()
            .insertFileEmbedGroup({ content: [fileNode], pos: insertAt })
            .setNodeSelection(insertAt)
            .scrollIntoView()
            .run();
        },
    };
  },
  addKeyboardShortcuts() {
    const handleModArrow = (editor: Editor, direction: "up" | "down") =>
      editor.commands.command(({ state, commands }) => {
        if (state.selection instanceof NodeSelection) {
          if (direction === "up") {
            commands.moveNodeUp();
          } else {
            commands.moveNodeDown();
          }
          return true;
        }
        return false;
      });
    return {
      "Mod-ArrowUp": ({ editor }) => handleModArrow(editor, "up"),
      "Mod-ArrowDown": ({ editor }) => handleModArrow(editor, "down"),
    };
  },
});
