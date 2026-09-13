import { PlayCircle, Trash, TwitterX, Video } from "@boxicons/react";
import { Editor, Extension, Node as TiptapNode } from "@tiptap/core";
import { DOMOutputSpec } from "@tiptap/pm/model";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import typia from "typia";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { sanitizeHtml } from "$app/utils/sanitize";

import { Button } from "$app/components/Button";
import { MenuItem } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { MenuItem as MenuListItem } from "$app/components/ui/Menu";
import { Row, RowActions, RowContent, RowDetails } from "$app/components/ui/Rows";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    mediaEmbed: {
      insertMediaEmbed: (options: { html: string; title: string; url: string }) => ReturnType;
    };
    raw: {
      setRaw: (options: { html: string; title: string; url: string; thumbnail?: string | undefined }) => ReturnType;
    };
  }
}

const MEDIA_EMBED_SUPPORTING_PROVIDERS = ["YouTube", "Vimeo", "Wistia, Inc.", "Dailymotion"];

const VideoEmbed = Extension.create({
  name: "videoEmbed",
  menuItem: (_editor, onOpen) => (
    <MenuItem name="Insert video" icon={<Video className="size-5" />} onClick={() => onOpen?.()} />
  ),
});

export const Raw = TiptapNode.create({
  name: "raw",
  inline: () => false,
  group: () => "block",
  draggable: true,
  addAttributes: () => ({
    html: { default: null },
    title: { default: null },
    url: { default: null },
    thumbnail: { default: null },
  }),
  parseHTML: () => [
    {
      tag: ".tiptap__raw",
      getAttrs: (node) =>
        node instanceof HTMLElement
          ? {
              html: node.innerHTML,
              title: node.getAttribute("data-title"),
              url: node.getAttribute("data-url"),
              thumbnail: node.getAttribute("data-thumbnail"),
            }
          : false,
    },
  ],
  renderHTML: ({ HTMLAttributes }) => {
    const doc = document.createElement("div");
    doc.className = "tiptap__raw";
    const processedHtml = sanitizeHtml(typia.assert<string>(HTMLAttributes.html));
    doc.innerHTML = processedHtml;
    if (HTMLAttributes.title) doc.setAttribute("data-title", typia.assert<string>(HTMLAttributes.title));
    if (HTMLAttributes.url) doc.setAttribute("data-url", typia.assert<string>(HTMLAttributes.url));
    if (HTMLAttributes.thumbnail) doc.setAttribute("data-thumbnail", typia.assert<string>(HTMLAttributes.thumbnail));
    const walk = (element: Element): DOMOutputSpec => {
      const attrs: Record<string, string> = {};
      for (const attr of element.attributes) attrs[attr.name] = attr.value;
      return [element.tagName, attrs, ...[...element.children].map(walk)];
    };
    return walk(doc);
  },
  menuItem: (_editor, onOpen) => (
    <MenuItem name="Insert post" icon={<TwitterX pack="brands" className="size-5" />} onClick={() => onOpen?.()} />
  ),
  submenu: {
    menu: "insert",
    item: (_editor, onOpen) => (
      <MenuListItem onClick={onOpen}>
        <TwitterX pack="brands" className="size-5" />
        <span>X post</span>
      </MenuListItem>
    ),
  },
  addCommands() {
    return {
      setRaw: createInsertCommand("raw"),
    };
  },
  addExtensions: () => [VideoEmbed],
});
type IframelyEmbedData = { html: string; title: string; url: string; provider_name: string; thumbnail_url?: string };

// Iframely stores the exact URL we ask for, so use one canonical spelling first and a distinct fallback.
const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/u;
const YOUTUBE_START_TIME = /^(?=\d)(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$/u;

const isYouTubeHost = (host: string) =>
  ["youtube.com", "youtube-nocookie.com"].some((domain) => host === domain || host.endsWith(`.${domain}`));

const youtubeVideoId = (url: URL): string | null => {
  const host = url.hostname.toLowerCase();
  const segments = url.pathname.split("/").filter(Boolean);
  if (host === "youtu.be") return segments[0] ?? null;
  if (!isYouTubeHost(host)) return null;
  if (segments[0] === "watch") return url.searchParams.get("v");
  if (["shorts", "embed", "live", "v"].includes(segments[0] ?? "")) return segments[1] ?? null;
  return null;
};

const youtubeStartSeconds = (value: string | null): number | null => {
  if (!value) return null;
  const match = YOUTUBE_START_TIME.exec(value);
  if (!match) return null;
  return Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number(match[3] ?? 0);
};

export const mediaEmbedUrlCandidates = (raw: string): string[] => {
  let parsed: URL;
  try {
    parsed = new URL(raw.trim());
  } catch {
    return [raw];
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return [raw];
  if (
    (parsed.hostname.toLowerCase() === "youtu.be" || isYouTubeHost(parsed.hostname.toLowerCase())) &&
    parsed.searchParams.has("list")
  )
    return [raw];
  // A path we don't recognize (a playlist, a channel, a mistyped id) is left exactly as typed.
  const id = youtubeVideoId(parsed);
  if (!id || !YOUTUBE_VIDEO_ID.test(id)) return [raw];
  const start = parsed.searchParams.get("t") ?? parsed.searchParams.get("start");
  const startSeconds = youtubeStartSeconds(start);
  const canonical = new URL(`https://www.youtube.com/watch?v=${id}`);
  const fallback = new URL(`https://www.youtube.com/embed/${id}`);
  if (start && startSeconds !== null) {
    canonical.searchParams.set("t", start);
    fallback.searchParams.set("start", String(startSeconds));
  }
  return [canonical.toString(), fallback.toString()];
};

export type EmbedMediaFormProps = {
  type: "embed" | "twitter";
  onEmbedReceived: ((data: IframelyEmbedData) => void) | undefined;
  horizontalLayout?: boolean;
  onClose: () => void;
};

export const EmbedMediaForm = React.forwardRef<{ focus: () => void }, EmbedMediaFormProps>(
  ({ type, onEmbedReceived, horizontalLayout = false, onClose }, ref) => {
    const inputUid = React.useId();
    const inputRef = React.useRef<HTMLInputElement>(null);
    React.useImperativeHandle(
      ref,
      () => ({
        focus: () => inputRef.current?.focus(),
      }),
      [],
    );

    const fields = (
      <>
        <Input
          id={inputUid}
          ref={inputRef}
          className="top-level-input"
          type="text"
          autoFocus
          placeholder={
            type === "embed" ? "https://youtu.be/Qku-fDzi3Os" : "https://x.com/gumroad/status/1663556902624845824"
          }
        />
        <div
          className="flex flex-wrap gap-2"
          style={{ alignSelf: "flex-end", gap: "var(--spacer-4)", marginTop: "var(--spacer-2)" }}
        >
          <Button onClick={onClose}>Cancel</Button>
          <Button
            color="primary"
            onClick={asyncVoid(async () => {
              if (!inputRef.current) {
                return;
              }
              // omit_script forces iframely to return an <iframe> tag
              const lookup = (url: string) =>
                request({
                  method: "GET",
                  url: `https://iframe.ly/api/oembed?iframe=1&api_key=6317bed3ca048a1a75d850&url=${encodeURIComponent(url)}&omit_script=1`,
                  accept: "json",
                });
              try {
                let data: unknown = null;
                for (const candidate of mediaEmbedUrlCandidates(inputRef.current.value)) {
                  data = await (await lookup(candidate)).json();
                  if (typia.is<IframelyEmbedData>(data)) break;
                }
                if (typia.is<IframelyEmbedData>(data)) {
                  inputRef.current.value = "";
                  onEmbedReceived?.(data);
                } else {
                  onClose();
                  showAlert(
                    type === "embed"
                      ? "Sorry, we couldn't embed this media. Please make sure the URL points to an embeddable media type."
                      : "Sorry, tweet URL is invalid.",
                    "error",
                  );
                }
              } catch (e) {
                inputRef.current.focus();
                assertResponseError(e);
                showAlert(e.message, "error");
              }
            })}
          >
            Insert
          </Button>
        </div>
      </>
    );
    return (
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={inputUid}>{type === "embed" ? "Video URL" : "Tweet URL"}</Label>
        </FieldsetTitle>
        {horizontalLayout ? <div className="flex gap-2">{fields}</div> : fields}
      </Fieldset>
    );
  },
);
EmbedMediaForm.displayName = "EmbedMediaForm";

export const insertMediaEmbed = (editor: Editor, data: IframelyEmbedData) => {
  if ("insertMediaEmbed" in editor.commands && MEDIA_EMBED_SUPPORTING_PROVIDERS.includes(data.provider_name)) {
    const responseHTML = new DOMParser().parseFromString(data.html, "text/html");
    const iframe = responseHTML.querySelector("iframe");
    const html = iframe ? iframe.outerHTML : data.html;
    editor.chain().focus().insertMediaEmbed({ html, title: data.title, url: data.url }).run();
  } else {
    editor
      .chain()
      .focus()
      .setRaw({ html: data.html, title: data.title, url: data.url, thumbnail: data.thumbnail_url })
      .run();
  }
};

export const ExternalMediaFileEmbed = TiptapNode.create({
  name: "mediaEmbed",
  selectable: false,
  draggable: true,
  atom: true,
  group: "block",
  addAttributes: () => ({ html: { default: null }, url: { default: null }, title: { default: null } }),
  parseHTML: () => [{ tag: "media-embed" }],
  renderHTML: ({ HTMLAttributes }) => ["media-embed", HTMLAttributes],
  addNodeView() {
    return ReactNodeViewRenderer(({ editor, node, deleteNode }: NodeViewProps) => (
      <NodeViewWrapper>
        <Row className="embed">
          <RowDetails
            className="preview"
            dangerouslySetInnerHTML={{ __html: sanitizeHtml(typia.assert<string>(node.attrs.html)) }}
          />
          <RowContent className="content">
            <PlayCircle pack="filled" className="type-icon size-5" />
            <div>
              <h4 className="truncate">{node.attrs.title}</h4>
              {node.attrs.url ? (
                <div className="truncate">
                  <a href={typia.assert<string>(node.attrs.url)} target="_blank" rel="noreferrer">
                    {node.attrs.url}
                  </a>
                </div>
              ) : null}
            </div>
          </RowContent>
          {editor.isEditable ? (
            <RowActions>
              <Button size="icon" color="danger" outline aria-label="Remove" onClick={deleteNode}>
                <Trash className="size-5" />
              </Button>
            </RowActions>
          ) : null}
        </Row>
      </NodeViewWrapper>
    ));
  },
  addCommands() {
    return {
      insertMediaEmbed: createInsertCommand("mediaEmbed"),
    };
  },
});
