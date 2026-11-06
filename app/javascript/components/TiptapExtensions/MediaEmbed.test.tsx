// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import { NodeSelection } from "@tiptap/pm/state";
import { EditorContent } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  DEFAULT_RAW_EMBED_HEIGHT,
  EmbedMediaForm,
  ExternalMediaFileEmbed,
  heyzineShelfUrl,
  insertMediaEmbed,
  mediaEmbedUrlCandidates,
  Raw,
  rawEmbedHeight,
  resizedRawEmbedHtml,
} from "$app/components/TiptapExtensions/MediaEmbed";

const state = vi.hoisted(() => ({ requests: new Array<string>(), bodies: new Array<unknown>() }));

vi.mock("$app/utils/request", () => ({
  request: async ({ url }: { url: string }) => {
    state.requests.push(url);
    return { json: async () => state.bodies[state.requests.length - 1] };
  },
  assertResponseError: () => undefined,
}));

const ID = "xwE0xYM0S6k";
const CANONICAL = `https://www.youtube.com/watch?v=${ID}`;
const EMBED_URL = `https://www.youtube.com/embed/${ID}`;
const SHORT_URL = `https://youtu.be/${ID}`;
const NOCOOKIE = `https://www.youtube-nocookie.com/embed/${ID}`;
const MOBILE = `https://m.youtube.com/watch?v=${ID}`;
const EMBED = {
  html: '<iframe src="about:blank"></iframe>',
  title: "Welcome",
  url: CANONICAL,
  provider_name: "YouTube",
};
const NOT_FOUND = { status: 404, error: "The content is no longer available at the origin" };

const askedUrls = () => state.requests.map((url) => new URL(url).searchParams.get("url"));

const insertUrl = async (value: string) => {
  const onEmbedReceived = vi.fn();
  render(<EmbedMediaForm type="embed" onEmbedReceived={onEmbedReceived} onClose={() => undefined} />);
  const input = document.querySelector<HTMLInputElement>("input.top-level-input");
  if (!input) throw new Error("embed input did not mount");
  input.value = value;
  const insert = [...document.querySelectorAll("button")].find((button) => button.textContent === "Insert");
  if (!insert) throw new Error("insert button did not mount");
  await act(async () => {
    fireEvent.click(insert);
  });
  return onEmbedReceived;
};

afterEach(() => {
  cleanup();
  state.requests.length = 0;
  state.bodies.length = 0;
});

describe("mediaEmbedUrlCandidates", () => {
  it("rewrites every YouTube spelling of a video to the canonical watch URL", () => {
    const forms = [
      `https://youtu.be/${ID}`,
      `https://www.youtube.com/watch?v=${ID}`,
      `https://youtube.com/watch?v=${ID}&feature=share`,
      `https://m.youtube.com/watch?v=${ID}`,
      `https://music.youtube.com/watch?v=${ID}`,
      `https://www.youtube.com/shorts/${ID}`,
      `https://www.youtube.com/embed/${ID}`,
      `https://www.youtube.com/live/${ID}`,
      `https://www.youtube-nocookie.com/embed/${ID}`,
      `https://youtu.be/${ID}?si=39y64u9WmoVVivHh`,
    ];

    for (const form of forms) {
      expect(mediaEmbedUrlCandidates(form)[0], form).toBe(CANONICAL);
    }
  });

  it("keeps a start offset, since dropping it would change what the embed plays", () => {
    expect(mediaEmbedUrlCandidates(`https://youtu.be/${ID}?t=42`)).toEqual([
      `${CANONICAL}&t=42`,
      `${EMBED_URL}?start=42`,
      `${SHORT_URL}?t=42`,
      `${NOCOOKIE}?start=42`,
      `${MOBILE}&t=42`,
    ]);
    expect(mediaEmbedUrlCandidates(`https://www.youtube.com/watch?v=${ID}&start=1m10s`)).toEqual([
      `${CANONICAL}&t=1m10s`,
      `${EMBED_URL}?start=70`,
      `${SHORT_URL}?t=1m10s`,
      `${NOCOOKIE}?start=70`,
      `${MOBILE}&t=1m10s`,
      `https://www.youtube.com/watch?v=${ID}&start=1m10s`,
    ]);
  });

  it("offers distinct spellings, so one poisoned cache key cannot kill the embed", () => {
    expect(mediaEmbedUrlCandidates(SHORT_URL)).toEqual([CANONICAL, EMBED_URL, SHORT_URL, NOCOOKIE, MOBILE]);
  });

  it("asks the spelling the seller pasted last, since its parameters make it a fresh cache key", () => {
    expect(mediaEmbedUrlCandidates(`https://youtu.be/${ID}?si=39y64u9WmoVVivHh`)).toEqual([
      CANONICAL,
      EMBED_URL,
      SHORT_URL,
      NOCOOKIE,
      MOBILE,
      `https://youtu.be/${ID}?si=39y64u9WmoVVivHh`,
    ]);
    expect(mediaEmbedUrlCandidates(`https://www.youtube.com/watch?v=${ID}&feature=share`)).toEqual([
      CANONICAL,
      EMBED_URL,
      SHORT_URL,
      NOCOOKIE,
      MOBILE,
      `https://www.youtube.com/watch?v=${ID}&feature=share`,
    ]);
  });

  it("passes playlist-context and non-YouTube URLs through unchanged", () => {
    for (const url of [
      "https://vimeo.com/76979871",
      "https://x.com/gumroad/status/1663556902624845824",
      "https://www.youtube.com/playlist?list=PL1234567890",
      `https://www.youtube.com/watch?v=${ID}&list=PL1234567890`,
      `https://youtu.be/${ID}?list=PL1234567890`,
      "https://www.youtube.com/@somechannel",
      "https://youtu.be/not-an-id",
      "youtu.be/xwE0xYM0S6k",
      "not a url at all",
    ]) {
      expect(mediaEmbedUrlCandidates(url), url).toEqual([url]);
    }
  });
});

describe("EmbedMediaForm", () => {
  it("asks for the canonical URL and stops there when iframely answers", async () => {
    state.bodies = [EMBED];

    const onEmbedReceived = await insertUrl(`https://youtu.be/${ID}?si=39y64u9WmoVVivHh`);

    expect(askedUrls()).toEqual([CANONICAL]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("retries with the fallback spelling before giving up on a stale lookup", async () => {
    state.bodies = [NOT_FOUND, EMBED];

    const onEmbedReceived = await insertUrl(`https://youtu.be/${ID}`);

    expect(askedUrls()).toEqual([CANONICAL, `https://www.youtube.com/embed/${ID}`]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("keeps walking distinct spellings when more than one lookup is poisoned", async () => {
    state.bodies = [NOT_FOUND, NOT_FOUND, EMBED];

    const onEmbedReceived = await insertUrl(SHORT_URL);

    expect(askedUrls()).toEqual([CANONICAL, EMBED_URL, SHORT_URL]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("gives up only after every spelling has been asked", async () => {
    state.bodies = [NOT_FOUND];

    const onEmbedReceived = await insertUrl(SHORT_URL);

    expect(askedUrls()).toEqual([CANONICAL, EMBED_URL, SHORT_URL, NOCOOKIE, MOBILE]);
    expect(onEmbedReceived).not.toHaveBeenCalled();
  });

  it("escapes on a later spelling when the pasted link is one of the poisoned ones", async () => {
    state.bodies = [NOT_FOUND, NOT_FOUND, NOT_FOUND, NOT_FOUND, EMBED];

    const onEmbedReceived = await insertUrl(SHORT_URL);

    expect(askedUrls()).toEqual([CANONICAL, EMBED_URL, SHORT_URL, NOCOOKIE, MOBILE]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("escapes on the pasted link when every generated spelling is poisoned", async () => {
    state.bodies = [NOT_FOUND, NOT_FOUND, NOT_FOUND, NOT_FOUND, NOT_FOUND, EMBED];

    const onEmbedReceived = await insertUrl(`https://youtu.be/${ID}?si=39y64u9WmoVVivHh`);

    expect(askedUrls()).toEqual([
      CANONICAL,
      EMBED_URL,
      SHORT_URL,
      NOCOOKIE,
      MOBILE,
      `https://youtu.be/${ID}?si=39y64u9WmoVVivHh`,
    ]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("does not retry a non-YouTube URL iframely cannot embed", async () => {
    state.bodies = [NOT_FOUND];

    await insertUrl("https://vimeo.com/76979871");

    expect(askedUrls()).toEqual(["https://vimeo.com/76979871"]);
  });
});

describe("ExternalMediaFileEmbed node view", () => {
  it("labels the remove control so the row does not rely on a bare icon", async () => {
    const editor = new Editor({
      extensions: [StarterKit, ExternalMediaFileEmbed],
      content: {
        type: "doc",
        content: [{ type: "mediaEmbed", attrs: { html: "<p>preview</p>", title: EMBED.title, url: EMBED.url } }],
      },
    });

    try {
      await act(async () => {
        render(<EditorContent editor={editor} />);
      });

      const remove = [...document.querySelectorAll("button")].find((button) => button.textContent.trim() === "Remove");

      expect(remove, "remove control did not mount").toBeDefined();
    } finally {
      editor.destroy();
    }
  });
});

describe("Raw node view", () => {
  const INTRO = { type: "paragraph", content: [{ type: "text", text: "Intro" }] };
  const RAW = {
    type: "raw",
    attrs: { html: '<iframe src="about:blank"></iframe>', title: "Flipbook", url: "https://heyzine.com/x" },
  };
  const mount = async (editable: boolean) => {
    const editor = new Editor({
      extensions: [StarterKit, Raw],
      editable,
      content: { type: "doc", content: [INTRO, RAW, { type: "horizontalRule" }] },
    });
    await act(async () => {
      render(<EditorContent editor={editor} />);
    });
    return editor;
  };
  const topLevelTypes = (editor: Editor) => editor.getJSON().content?.map((node) => node.type);

  it("selects the block on a click that reaches it, so Backspace removes it and not its neighbour", async () => {
    const editor = await mount(true);
    try {
      const embed = editor.view.dom.querySelector<HTMLElement>(".tiptap__raw");
      if (!embed) throw new Error("embed did not mount");
      expect(embed.classList).toContain("[&_iframe]:pointer-events-none");
      // happy-dom has no layout, so hand ProseMirror the clicked element; the system spec covers
      // the iframe letting the click through.
      vi.spyOn(document, "elementFromPoint").mockReturnValue(embed);
      expect(editor.state.selection instanceof NodeSelection).toBe(false);
      await act(async () => {
        fireEvent.mouseDown(embed, { button: 0, clientX: 1, clientY: 1 });
        fireEvent.mouseUp(embed, { button: 0, clientX: 1, clientY: 1 });
      });
      const { selection } = editor.state;
      expect(selection instanceof NodeSelection && selection.node.type.name).toBe("raw");

      act(() => {
        editor.commands.keyboardShortcut("Backspace");
      });
      expect(topLevelTypes(editor)).toEqual(["paragraph", "horizontalRule"]);
    } finally {
      vi.restoreAllMocks();
      editor.destroy();
    }
  });

  it("offers a Delete action that removes the block only while editing", async () => {
    const editor = await mount(true);
    try {
      const trigger = document.querySelector<HTMLElement>("[aria-label='Actions']");
      if (!trigger) throw new Error("actions menu did not mount");
      await act(async () => {
        fireEvent.click(trigger);
      });
      await act(async () => {
        fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
      });
      expect(topLevelTypes(editor)).toEqual(["paragraph", "horizontalRule"]);
    } finally {
      editor.destroy();
    }

    const readOnly = await mount(false);
    try {
      const embed = readOnly.view.dom.querySelector(".tiptap__raw");
      expect(embed?.parentElement).toBe(readOnly.view.dom);
      expect(embed?.getAttribute("data-url")).toBe("https://heyzine.com/x");
      expect(readOnly.view.dom.querySelector("[aria-label='Actions']")).toBeNull();
    } finally {
      readOnly.destroy();
    }
  });
});

const RESPONSIVE_VIDEO =
  '<div style="left: 0; width: 100%; height: 0px; position: relative; padding-bottom: 56.25%;"><iframe src="about:blank" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen=""></iframe></div>';

const HEYZINE_SHELF = {
  html: '<div><div style="left: 0; width: 100%; height: 170px; position: relative;"><iframe src="about:blank" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen=""></iframe></div></div>',
  title: "Online flipbook bookshelf",
  url: "https://heyzine.com/shelf/66f3c4fc1e.html",
  thumbnail_url: "https://cdnm.heyzine.com/files/library-thumb.jpg",
};

// What iframely actually answers for a shelf: a card wrapping a frame to its own proxy, with no live
// page behind it (see gumroad-private#4343).
const HEYZINE_SHELF_LOOKUP = {
  ...HEYZINE_SHELF,
  html: HEYZINE_SHELF.html.replace(
    "about:blank",
    "https://iframely.net/api/iframe?app=1&url=https%3A%2F%2Fheyzine.com%2Fshelf%2F66f3c4fc1e.html&key=abc",
  ),
};

describe("heyzineShelfUrl", () => {
  it("recognizes a shelf page and drops the parts of the URL that page does not use", () => {
    expect(heyzineShelfUrl("https://heyzine.com/shelf/66f3c4fc1e.html")).toBe(
      "https://heyzine.com/shelf/66f3c4fc1e.html",
    );
    expect(heyzineShelfUrl("  https://heyzine.com/shelf/66f3c4fc1e.html?utm_source=x#page-2  ")).toBe(
      "https://heyzine.com/shelf/66f3c4fc1e.html",
    );
  });

  it("recognizes the named shelf address Heyzine serves as the page's canonical URL", () => {
    expect(heyzineShelfUrl("https://heyzine.com/shelf/turningtopeacelibrary")).toBe(
      "https://heyzine.com/shelf/turningtopeacelibrary",
    );
    expect(heyzineShelfUrl("  https://heyzine.com/shelf/turningtopeacelibrary?utm_source=x#page-2  ")).toBe(
      "https://heyzine.com/shelf/turningtopeacelibrary",
    );
  });

  it.each([
    "https://heyzine.com/flip-book/66f3c4fc1e.html",
    "https://heyzine.com/shelf/",
    "https://heyzine.com/shelf/66f3c4fc1e.html.evil",
    "https://heyzine.com/shelf/turningtopeacelibrary.html.evil",
    "https://heyzine.com/shelf/turningtopeacelibrary/2",
    "https://www.heyzine.com/shelf/66f3c4fc1e.html",
    "https://www.heyzine.com/shelf/turningtopeacelibrary",
    "https://heyzine.com.evil.test/shelf/66f3c4fc1e.html",
    "http://heyzine.com/shelf/66f3c4fc1e.html",
    "http://heyzine.com/shelf/turningtopeacelibrary",
    "not a url at all",
  ])("leaves %s alone", (url) => {
    expect(heyzineShelfUrl(url)).toBeNull();
  });
});

describe("rich embeds with no provider metadata", () => {
  it("accepts a lookup whose response omits provider_name", async () => {
    state.bodies = [HEYZINE_SHELF];

    const onEmbedReceived = await insertUrl(HEYZINE_SHELF.url);

    expect(askedUrls()).toEqual([HEYZINE_SHELF.url]);
    expect(onEmbedReceived).toHaveBeenCalledWith(HEYZINE_SHELF);
  });

  it("still rejects a response that carries no embed html", async () => {
    state.bodies = [{ type: "link", title: "Page not found", url: HEYZINE_SHELF.url }];

    const onEmbedReceived = await insertUrl(HEYZINE_SHELF.url);

    expect(onEmbedReceived).not.toHaveBeenCalled();
  });
});

describe("raw embed height", () => {
  it("reads the fixed height iframely puts around the frame", () => {
    expect(rawEmbedHeight(HEYZINE_SHELF.html)).toBe(170);
    expect(rawEmbedHeight('<div style="padding-bottom: 56.25%;"><iframe src="about:blank"></iframe></div>')).toBeNull();
  });

  it("ignores a wrapper shaped by percentage padding, so a responsive video is not stretched", () => {
    const video = RESPONSIVE_VIDEO;

    expect(rawEmbedHeight(video)).toBeNull();
    expect(resizedRawEmbedHtml(video, 1200)).toBe(video);
  });

  it("preserves the provider height through repeated resizing and HTML round trips", () => {
    const resized = resizedRawEmbedHtml(resizedRawEmbedHtml(HEYZINE_SHELF.html, 800), 1800);
    const editor = new Editor({
      extensions: [StarterKit, Raw],
      content: { type: "doc", content: [{ type: "raw", attrs: { html: resized } }] },
    });
    try {
      const saved = editor.getHTML();
      expect(saved).toContain('data-original-height="170px"');
      editor.commands.setContent(saved);
      act(() => {
        render(<EditorContent editor={editor} />);
      });
      act(() => {
        fireEvent.click(screen.getByRole("button", { name: "Actions" }));
      });
      act(() => {
        fireEvent.click(screen.getByRole("menuitem", { name: "Height" }));
      });
      act(() => {
        fireEvent.click(screen.getByRole("menuitem", { name: "170 px" }));
      });
      const raw = editor.getJSON().content?.find((node) => node.type === "raw");
      expect(rawEmbedHeight(String(raw?.attrs?.html))).toBe(170);
    } finally {
      editor.destroy();
    }
  });

  it("rewrites only that height, keeping the frame and its wrapper markup", () => {
    const html = resizedRawEmbedHtml(HEYZINE_SHELF.html, 1200);

    expect(rawEmbedHeight(html)).toBe(1200);
    expect(html).toContain('src="about:blank"');
    expect(html).toContain("position: absolute");
  });
});

describe("insertMediaEmbed", () => {
  const editorWith = (content: object) =>
    new Editor({ extensions: [StarterKit, Raw, ExternalMediaFileEmbed], content });

  const insertedNode = (editor: Editor) =>
    editor.getJSON().content?.find((node) => node.type === "raw" || node.type === "mediaEmbed");

  it("stores a form embed as a block tall enough to hold a quiz", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, { ...HEYZINE_SHELF, url: "https://tally.so/r/1" });

      const node = insertedNode(editor);
      expect(node?.type).toBe("raw");
      expect(rawEmbedHeight(String(node?.attrs?.html))).toBe(DEFAULT_RAW_EMBED_HEIGHT);
      expect(String(node?.attrs?.html)).toContain('src="about:blank"');
    } finally {
      editor.destroy();
    }
  });

  it("frames the shelf itself, since iframely only offers a preview card for it", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, HEYZINE_SHELF_LOOKUP);

      const node = insertedNode(editor);
      const html = String(node?.attrs?.html);
      expect(html).toContain('src="https://heyzine.com/shelf/66f3c4fc1e.html"');
      expect(html).not.toContain("iframely.net");
      expect(rawEmbedHeight(html)).toBe(DEFAULT_RAW_EMBED_HEIGHT);
      // The link an email falls back to still opens the seller's library.
      expect(node?.attrs?.url).toBe("https://heyzine.com/shelf/66f3c4fc1e.html");
    } finally {
      editor.destroy();
    }
  });

  it("frames the named shelf address too, which is what the seller's page links", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, { ...HEYZINE_SHELF_LOOKUP, url: "https://heyzine.com/shelf/turningtopeacelibrary" });

      const node = insertedNode(editor);
      const html = String(node?.attrs?.html);
      expect(html).toContain('src="https://heyzine.com/shelf/turningtopeacelibrary"');
      expect(html).not.toContain("iframely.net");
      expect(rawEmbedHeight(html)).toBe(DEFAULT_RAW_EMBED_HEIGHT);
      expect(node?.attrs?.url).toBe("https://heyzine.com/shelf/turningtopeacelibrary");
    } finally {
      editor.destroy();
    }
  });

  it("keeps iframely's html for a Heyzine page that is not a shelf", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, { ...HEYZINE_SHELF_LOOKUP, url: "https://heyzine.com/flip-book/66f3c4fc1e.html" });

      const html = String(insertedNode(editor)?.attrs?.html);
      expect(html).toContain("iframely.net/api/iframe");
      expect(html).not.toContain('src="https://heyzine.com/flip-book/');
      expect(rawEmbedHeight(html)).toBe(DEFAULT_RAW_EMBED_HEIGHT);
    } finally {
      editor.destroy();
    }
  });

  it("stores a provider's responsive video layout without a pixel height", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, { ...HEYZINE_SHELF, html: RESPONSIVE_VIDEO, url: "https://tally.so/r/1" });

      expect(String(insertedNode(editor)?.attrs?.html)).toBe(RESPONSIVE_VIDEO);
    } finally {
      editor.destroy();
    }
  });

  it.each([
    ["Spotify", 152],
    ["SoundCloud", 166],
  ])("keeps the height %s asked for", (provider, height) => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, {
        html: `<div style="left: 0; width: 100%; height: ${height}px; position: relative;"><iframe src="about:blank" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;"></iframe></div>`,
        title: "A track",
        url: "https://example.com/track/1",
        provider_name: provider,
        thumbnail_url: "https://example.com/cover",
      });

      expect(rawEmbedHeight(String(insertedNode(editor)?.attrs?.html))).toBe(height);
    } finally {
      editor.destroy();
    }
  });

  it("grows a provider whose own embed is clipped", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, {
        html: '<div style="height: 600px; position: relative;"><iframe src="about:blank" style="width: 100%; height: 100%; border: 0;"></iframe></div>',
        title: "A quiz",
        url: "https://tally.so/r/1",
        provider_name: "Tally Forms",
      });

      expect(rawEmbedHeight(String(insertedNode(editor)?.attrs?.html))).toBe(DEFAULT_RAW_EMBED_HEIGHT);
    } finally {
      editor.destroy();
    }
  });

  it("keeps a frame the provider already sized taller than the default", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, {
        ...HEYZINE_SHELF,
        url: "https://tally.so/r/1",
        html: resizedRawEmbedHtml(HEYZINE_SHELF.html, 1200),
      });

      expect(rawEmbedHeight(String(insertedNode(editor)?.attrs?.html))).toBe(1200);
    } finally {
      editor.destroy();
    }
  });

  it("still inserts a whitelisted video provider through the media embed node", () => {
    const editor = editorWith({ type: "doc", content: [{ type: "paragraph" }] });
    try {
      insertMediaEmbed(editor, EMBED);

      const node = insertedNode(editor);
      expect(node?.type).toBe("mediaEmbed");
      expect(String(node?.attrs?.html)).toBe('<iframe src="about:blank"></iframe>');
    } finally {
      editor.destroy();
    }
  });
});

describe("raw embed height menu", () => {
  it("sets a taller frame on the block so a long form is not clipped", () => {
    const editor = new Editor({
      extensions: [StarterKit, Raw],
      content: {
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Intro" }] },
          { type: "raw", attrs: { html: HEYZINE_SHELF.html, title: HEYZINE_SHELF.title, url: HEYZINE_SHELF.url } },
        ],
      },
    });
    try {
      act(() => {
        render(<EditorContent editor={editor} />);
      });

      const trigger = document.querySelector<HTMLElement>("[aria-label='Actions']");
      if (!trigger) throw new Error("actions menu did not mount");
      act(() => {
        fireEvent.click(trigger);
      });
      act(() => {
        fireEvent.click(screen.getByRole("menuitem", { name: "Height" }));
      });
      expect(screen.getByRole("menuitem", { name: "170 px" }), "provider height is not restorable").toBeDefined();
      act(() => {
        fireEvent.click(screen.getByRole("menuitem", { name: "1800 px" }));
      });

      const raw = editor.getJSON().content?.find((node) => node.type === "raw");
      expect(rawEmbedHeight(String(raw?.attrs?.html))).toBe(1800);

      act(() => {
        fireEvent.click(trigger);
      });
      act(() => {
        fireEvent.click(screen.getByRole("menuitem", { name: "170 px" }));
      });
      const restored = editor.getJSON().content?.find((node) => node.type === "raw");
      expect(rawEmbedHeight(String(restored?.attrs?.html))).toBe(170);
    } finally {
      editor.destroy();
    }
  });
});
