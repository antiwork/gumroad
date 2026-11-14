// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import { EditorContent } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Button as TiptapButton } from "$app/components/TiptapExtensions/Link";

const DOC = {
  type: "doc",
  content: [
    { type: "paragraph", content: [{ type: "text", text: "Intro" }] },
    { type: "button", attrs: { href: "https://example.com" }, content: [{ type: "text", text: "Click" }] },
  ],
};

let editor: Editor | null = null;

afterEach(() => {
  cleanup();
  editor?.destroy();
  editor = null;
});

const mount = async (editable: boolean) => {
  const instance = new Editor({ editable, extensions: [StarterKit, TiptapButton], content: DOC });
  editor = instance;
  await act(async () => {
    render(<EditorContent editor={instance} />);
  });
  return instance;
};

const buttonCount = (editor: Editor) => {
  let count = 0;
  editor.state.doc.descendants((node) => {
    if (node.type.name === "button") count += 1;
  });
  return count;
};

describe("button node view", () => {
  it("offers block actions so a button the seller inserted can be deleted", async () => {
    const editor = await mount(true);
    expect(buttonCount(editor)).toBe(1);

    const trigger = document.querySelector<HTMLElement>("[aria-label='Actions']");
    if (!trigger) throw new Error("actions menu did not mount");

    await act(async () => {
      fireEvent.click(trigger);
    });
    expect(screen.getByRole("menuitem", { name: "Move up" })).toBeDefined();
    expect(screen.getByRole("menuitem", { name: "Move down" })).toBeDefined();

    await act(async () => {
      fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
    });
    expect(buttonCount(editor)).toBe(0);
  });

  it("does not offer block actions in a read-only editor", async () => {
    await mount(false);
    expect(document.querySelector("[aria-label='Actions']")).toBeNull();
  });
});
