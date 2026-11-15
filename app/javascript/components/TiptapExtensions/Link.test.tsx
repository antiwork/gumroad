// @vitest-environment happy-dom
import { act, cleanup, createEvent, fireEvent, render, screen } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import { EditorContent } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { LinkDialog, Button as TiptapButton } from "$app/components/TiptapExtensions/Link";

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

// The flag is defined on the event directly so the test does not depend on which KeyboardEvent init fields happy-dom
// honours.
const pressEnter = async (target: HTMLElement, { isComposing }: { isComposing: boolean }) => {
  const event = createEvent.keyDown(target, { key: "Enter" });
  Object.defineProperty(event, "isComposing", { value: isComposing });
  await act(async () => {
    fireEvent(target, event);
  });
};

const buttonLabels = (editor: Editor) => {
  const labels: string[] = [];
  editor.state.doc.descendants((node) => {
    if (node.type.name === "button") labels.push(node.textContent);
  });
  return labels;
};

describe("Enter during IME composition", () => {
  it("does not save the button popover until the composition is confirmed", async () => {
    const editor = await mount(true);
    const trigger = document.querySelector<HTMLElement>("a[href='https://example.com']")?.closest("button");
    if (!trigger) throw new Error("popover trigger did not mount");
    await act(async () => {
      fireEvent.click(trigger);
    });

    const labelInput = screen.getByPlaceholderText("Enter text");
    await act(async () => {
      fireEvent.change(labelInput, { target: { value: "購入" } });
    });

    await pressEnter(labelInput, { isComposing: true });
    expect(buttonLabels(editor)).toEqual(["Click"]);

    await pressEnter(screen.getByPlaceholderText("Enter text"), { isComposing: false });
    expect(buttonLabels(editor)).toEqual(["購入"]);
  });

  it("does not insert from the dialog until the composition is confirmed", async () => {
    const instance = new Editor({ extensions: [StarterKit, TiptapButton], content: DOC });
    editor = instance;
    const onClose = vi.fn();
    await act(async () => {
      render(<LinkDialog editor={instance} type="button" onClose={onClose} />);
    });
    await act(async () => {
      fireEvent.change(screen.getByPlaceholderText("Enter text"), { target: { value: "購入" } });
      fireEvent.change(screen.getByPlaceholderText("Enter URL"), { target: { value: "https://example.com/buy" } });
    });

    for (const placeholder of ["Enter text", "Enter URL"]) {
      await pressEnter(screen.getByPlaceholderText(placeholder), { isComposing: true });
      expect(onClose).not.toHaveBeenCalled();
      expect(buttonLabels(instance)).toEqual(["Click"]);
    }

    await pressEnter(screen.getByPlaceholderText("Enter URL"), { isComposing: false });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(buttonLabels(instance)).toContain("購入");
  });
});
