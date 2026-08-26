// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import { Editor, getSchema, Node } from "@tiptap/core";
import { undoDepth } from "@tiptap/pm/history";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  dropUnknownNodes,
  lastContentResetFailed,
  useRichTextEditor,
  validateUrl,
} from "$app/components/RichTextEditor";
import { emailPrimaryButtonStyle, tiptapButtonClassName } from "$app/components/TiptapExtensions/Link";

// vite.config.ts's `define` replaces the bare `SSR` identifier at build time; vitest doesn't run
// through that build step, so stub the global here for the hook test below.
Object.assign(globalThis, { SSR: false });

afterEach(cleanup);

describe("Tiptap button styling", () => {
  it("renders inserted buttons as always-visible accent CTAs", () => {
    expect(tiptapButtonClassName).toContain("bg-accent-with-text");
    expect(tiptapButtonClassName).toContain("text-accent-foreground");
    expect(tiptapButtonClassName).toContain("-translate-1");
    expect(tiptapButtonClassName).toContain("shadow-[0.25rem_0.25rem_0_var(--color-black)]");
    expect(tiptapButtonClassName).not.toContain("bg-primary text-primary-foreground");
  });

  it("serializes buttons with email-safe pink fill and persistent depth", async () => {
    const initialValue = {
      type: "doc",
      content: [
        { type: "button", attrs: { href: "https://example.com/" }, content: [{ type: "text", text: "Read more" }] },
      ],
    };
    let editor: Editor | null = null;
    const Harness = () => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    render(React.createElement(Harness));
    await act(async () => {
      await Promise.resolve();
    });

    expect(getEditor().getHTML()).toContain('class="tiptap__button button primary"');
    expect(getEditor().getHTML()).toContain(`style="${emailPrimaryButtonStyle}"`);
  });
});

describe("validateUrl", () => {
  it("rejects empty input", () => {
    expect(validateUrl()).toBe(false);
    expect(validateUrl("")).toBe(false);
    expect(validateUrl("   ")).toBe(false);
  });

  it("adds https:// when no scheme is given", () => {
    expect(validateUrl("example.com")).toBe("https://example.com/");
    expect(validateUrl("example.com/path?a=1")).toBe("https://example.com/path?a=1");
  });

  it("adds https:// to a bare host with a port, rather than reading the host as a scheme", () => {
    expect(validateUrl("example.com:8080/path")).toBe("https://example.com:8080/path");
  });

  it("repairs mistyped http(s) schemes", () => {
    expect(validateUrl("http:/example.com")).toBe("https://example.com/");
    expect(validateUrl("https//example.com")).toBe("https://example.com/");
  });

  it("keeps custom app schemes so sellers can deep-link into their own app", () => {
    expect(validateUrl("goodsnooze://activate?key=__license_key__")).toBe("goodsnooze://activate?key=__license_key__");
    expect(validateUrl("my-app.desktop://open")).toBe("my-app.desktop://open");
  });

  it("rejects schemes that can execute script or read local resources", () => {
    expect(validateUrl("javascript://%0aalert(1)")).toBe(false);
    expect(validateUrl("JavaScript://alert(1)")).toBe(false);
    expect(validateUrl("data://text/html,<script>alert(1)</script>")).toBe(false);
    expect(validateUrl("vbscript://msgbox(1)")).toBe(false);
    expect(validateUrl("file:///etc/passwd")).toBe(false);
    expect(validateUrl("blob://something")).toBe(false);
  });

  it("rejects input that is not a URL at all", () => {
    expect(validateUrl("http://")).toBe(false);
  });
});

describe("dropUnknownNodes", () => {
  const schema = getSchema([StarterKit]);

  it("drops a node type the schema doesn't know, keeping its siblings", () => {
    const content = [
      { type: "paragraph", content: [{ type: "text", text: "before" }] },
      { type: "license", attrs: {} },
      { type: "paragraph", content: [{ type: "text", text: "after" }] },
    ];

    expect(dropUnknownNodes(content, schema)).toEqual([
      { type: "paragraph", content: [{ type: "text", text: "before" }] },
      { type: "paragraph", content: [{ type: "text", text: "after" }] },
    ]);
  });

  it("drops an unknown node nested inside a known container without dropping the container", () => {
    const content = [
      {
        type: "blockquote",
        content: [
          { type: "license", attrs: {} },
          { type: "paragraph", content: [{ type: "text", text: "kept" }] },
        ],
      },
    ];

    expect(dropUnknownNodes(content, schema)).toEqual([
      { type: "blockquote", content: [{ type: "paragraph", content: [{ type: "text", text: "kept" }] }] },
    ]);
  });

  it("leaves a document made only of known node types untouched", () => {
    const content = [{ type: "paragraph", content: [{ type: "text", text: "hello" }] }];
    expect(dropUnknownNodes(content, schema)).toEqual(content);
  });

  it("strips a mark type the schema doesn't know without dropping the text that carries it", () => {
    const content = [
      {
        type: "paragraph",
        content: [{ type: "text", text: "kept", marks: [{ type: "sparkle" }, { type: "bold" }] }],
      },
    ];

    expect(dropUnknownNodes(content, schema)).toEqual([
      { type: "paragraph", content: [{ type: "text", text: "kept", marks: [{ type: "bold" }] }] },
    ]);
  });
});

describe("useRichTextEditor", () => {
  // Regression for a P1 caught by Greptile on this PR: the content memo used to depend on
  // `dedupedExtensions`, a fresh array every render, so an unrelated parent rerender (same
  // `initialValue`) gave `content` a new identity and the sync effect discarded live edits.
  it("keeps in-progress edits and undo history across a parent rerender with unchanged initialValue", async () => {
    const initialValue = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "saved" }] }] };
    let editor: Editor | null = null;
    const Harness = (_props: { tick: number }) => {
      editor = useRichTextEditor({ initialValue });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    const { rerender } = render(React.createElement(Harness, { tick: 0 }));
    act(() => {
      getEditor().chain().focus("end").insertContent(" draft").run();
    });
    expect(getEditor().getText()).toBe("saved draft");
    expect(undoDepth(getEditor().state)).toBe(1);

    // Same initialValue, different unrelated prop — this must not reset the live document.
    // The content-sync effect schedules its reset via queueMicrotask, so flush one before asserting.
    rerender(React.createElement(Harness, { tick: 1 }));
    await act(async () => {
      await Promise.resolve();
    });

    expect(getEditor().getText()).toBe("saved draft");
    expect(undoDepth(getEditor().state)).toBe(1);
  });

  // Regression for a P1 Greptile caught on this PR: `useEditor` is called with `deps: []`, so
  // the mounted editor keeps its ORIGINAL schema even after a rerender adds a new extension.
  // Sanitizing against the freshly-computed (extension-added) schema would let a node type through
  // that the still-mounted (extension-less) editor can't parse, reproducing the exact
  // "Unknown node type" crash this file exists to prevent — just one extension-set change later.
  it("sanitizes new content against the mounted editor's schema, not a freshly recomputed one", async () => {
    const LateExtension = Node.create({ name: "lateNode", group: "block", content: "text*" });
    let editor: Editor | null = null;
    const Harness = ({ extensions, initialValue }: { extensions: (typeof LateExtension)[]; initialValue: unknown }) => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never, extensions });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    const initial = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "first" }] }] };
    const { rerender } = render(React.createElement(Harness, { extensions: [], initialValue: initial }));
    expect(getEditor().getText()).toBe("first");

    // The editor is never recreated (rerender doesn't remount), so its schema still doesn't know
    // "lateNode" even though this render's `extensions` prop now includes it.
    const next = {
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "before" }] },
        { type: "lateNode", content: [{ type: "text", text: "dropped" }] },
        { type: "paragraph", content: [{ type: "text", text: "after" }] },
      ],
    };
    expect(() =>
      rerender(React.createElement(Harness, { extensions: [LateExtension], initialValue: next })),
    ).not.toThrow();
    await act(async () => {
      await Promise.resolve();
    });

    expect(getEditor().getText()).toBe("before\n\nafter");
  });

  // The window ContentTab's editorContentPageIdRef guard exists for (gumroad-private#1943):
  // after initialValue changes, the mounted doc is only swapped in a queueMicrotask, so an
  // update/blur handler firing synchronously in that window still reads the PREVIOUS page's
  // doc. Serializing it into the newly selected page crosses page/variant content.
  it("still holds the previous doc between an initialValue change and the deferred reset", async () => {
    let editor: Editor | null = null;
    const Harness = ({ initialValue }: { initialValue: object }) => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    const pageA = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "PAGE A" }] }] };
    const pageB = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "PAGE B" }] }] };
    const { rerender } = render(React.createElement(Harness, { initialValue: pageA }));
    expect(getEditor().getText()).toBe("PAGE A");

    // Synchronously after the switch — before microtasks flush — the editor still serializes
    // page A. Anything persisting editor state here must not attribute it to page B.
    rerender(React.createElement(Harness, { initialValue: pageB }));
    expect(getEditor().getText()).toBe("PAGE A");

    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("PAGE B");
  });

  // queueMicrotask swallows exceptions, so a refused doc used to leave the
  // previous content mounted with no signal to block writes.
  it("keeps the previous doc, records the failure, and recovers when a reset throws", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    let editor: Editor | null = null;
    const Harness = ({ initialValue }: { initialValue: object }) => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    const valid = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "first" }] }] };
    // A known node type with an invalid shape: dropUnknownNodes keeps it, and
    // ProseMirror's nodeFromJSON throws on a text node without text.
    const poison = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] };
    const { rerender } = render(React.createElement(Harness, { initialValue: valid }));
    expect(getEditor().getText()).toBe("first");

    rerender(React.createElement(Harness, { initialValue: poison }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("first");
    expect(lastContentResetFailed(getEditor())).toBe(true);
    expect(consoleError).toHaveBeenCalledWith("RichTextEditor: content reset failed", expect.anything());

    const next = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "second" }] }] };
    rerender(React.createElement(Harness, { initialValue: next }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("second");
    expect(lastContentResetFailed(getEditor())).toBe(false);
    consoleError.mockRestore();
  });

  // Stored product HTML legitimately contains tags with no schema rule; the
  // lenient DOM parse keeps their supported children.
  it("keeps parsing HTML strings leniently when they contain unsupported tags", async () => {
    let editor: Editor | null = null;
    const Harness = ({ initialValue }: { initialValue: string }) => {
      editor = useRichTextEditor({ initialValue });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    const { rerender } = render(React.createElement(Harness, { initialValue: "<p>first</p>" }));
    expect(getEditor().getText()).toBe("first");

    rerender(React.createElement(Harness, { initialValue: "<p><span>kept</span></p>" }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("kept");
    expect(lastContentResetFailed(getEditor())).toBe(false);
  });

  // useEditor mounts an EMPTY doc for malformed initial content; the strict
  // check must also cover the first content once the editor materializes.
  it("records the failure when the INITIAL content is malformed", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    let editor: Editor | null = null;
    const Harness = ({ initialValue }: { initialValue: object }) => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never });
      return null;
    };

    const poison = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] };
    render(React.createElement(Harness, { initialValue: poison }));
    await act(async () => {
      await Promise.resolve();
    });
    if (!editor) throw new Error("editor did not mount");
    expect(lastContentResetFailed(editor)).toBe(true);
    expect(consoleError).toHaveBeenCalledWith("RichTextEditor: content reset failed", expect.anything());
    consoleError.mockRestore();
  });

  // Returning to the previous content must reset even when its identity never
  // changed, or stray edits typed over the stale doc get attributed to it.
  it("discards edits made over a stale doc when returning to the last valid content", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    let editor: Editor | null = null;
    const Harness = ({ initialValue }: { initialValue: object | string }) => {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- exercising the hook's public Content type
      editor = useRichTextEditor({ initialValue: initialValue as never });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };

    // String content compares by value across recomputes — the one path where
    // the identity check alone would skip the recovery reset.
    const pageA = "<p>PAGE A</p>";
    const poison = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] };
    const { rerender } = render(React.createElement(Harness, { initialValue: pageA }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("PAGE A");

    rerender(React.createElement(Harness, { initialValue: poison }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(lastContentResetFailed(getEditor())).toBe(true);
    act(() => {
      getEditor().chain().focus("end").insertContent(" STRAY").run();
    });
    expect(getEditor().getText()).toBe("PAGE A STRAY");

    rerender(React.createElement(Harness, { initialValue: pageA }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(getEditor().getText()).toBe("PAGE A");
    expect(lastContentResetFailed(getEditor())).toBe(false);
    consoleError.mockRestore();
  });

  it("includes the upsell card node by default so product/email/profile editors keep Insert Upsell", () => {
    const initialValue = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "x" }] }] };
    let editor: Editor | null = null;
    const Harness = () => {
      editor = useRichTextEditor({ initialValue });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };
    render(React.createElement(Harness));
    expect(getEditor().schema.nodes.upsellCard).toBeDefined();
  });

  it("omits the upsell card node when allowUpsells is false", () => {
    const initialValue = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "x" }] }] };
    let editor: Editor | null = null;
    const Harness = () => {
      editor = useRichTextEditor({ initialValue, allowUpsells: false });
      return null;
    };
    const getEditor = (): Editor => {
      if (!editor) throw new Error("editor did not mount");
      return editor;
    };
    render(React.createElement(Harness));
    expect(getEditor().schema.nodes.upsellCard).toBeUndefined();
  });
});
