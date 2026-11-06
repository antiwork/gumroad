import { PlayCircle, RowResize, Trash, TwitterX, Video } from "@boxicons/react";
import { Editor, Extension, Node as TiptapNode } from "@tiptap/core";
import { DOMOutputSpec, DOMSerializer, Node as ProseMirrorNode } from "@tiptap/pm/model";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";

import { assertString, isRecord, isString } from "$app/utils/guards";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { sanitizeHtml } from "$app/utils/sanitize";

import { Button } from "$app/components/Button";
import { MenuItem } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { NodeActionsMenu, NodeActionsWrapper } from "$app/components/TiptapExtensions/NodeActionsMenu";
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

// Iframely sizes a rich embed by putting a fixed pixel height on the div wrapping the frame, and
// the frame is 100% of it: the number it picks is what clips a long form or squashes a bookshelf.
const EMBED_HEIGHT_PX = /^(\d+(?:\.\d+)?)px$/u;
// Videos come back as a wrapper shaped by percentage padding (usually height 0) instead. That box
// sizes itself, so a pixel height next to it would stack on top of the ratio.
const PERCENT_PADDING = /padding(?:-[a-z]+)?\s*:\s*[^;]*%/iu;

export const DEFAULT_RAW_EMBED_HEIGHT = 800;
export const RAW_EMBED_HEIGHT_OPTIONS = [560, 800, 1200, 1800];

const embedHeightWrapper = (doc: Document): HTMLElement | null => {
  const wrapper = doc.querySelector("iframe")?.parentElement;
  if (!wrapper || wrapper === doc.body) return null;
  if (PERCENT_PADDING.test(wrapper.getAttribute("style") ?? "")) return null;
  const declared = EMBED_HEIGHT_PX.exec(wrapper.style.height.trim().toLowerCase());
  return declared && Number(declared[1]) > 0 ? wrapper : null;
};

export const rawEmbedHeight = (html: string): number | null => {
  const wrapper = embedHeightWrapper(new DOMParser().parseFromString(html, "text/html"));
  const match = wrapper ? EMBED_HEIGHT_PX.exec(wrapper.style.height.trim().toLowerCase()) : null;
  return match ? Number(match[1]) : null;
};

export const resizedRawEmbedHtml = (html: string, height: number): string => {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const wrapper = embedHeightWrapper(doc);
  if (!wrapper) return html;
  // Retain the provider's size in saved HTML so resizing remains reversible after reload.
  if (!wrapper.hasAttribute("data-original-height")) {
    wrapper.setAttribute("data-original-height", wrapper.style.height);
  }
  wrapper.style.height = `${height}px`;
  return doc.body.innerHTML;
};

// Only a provider that clips its own embed gets a taller frame than iframely asked for (a Tally
// quiz is pinned at 600px, a Heyzine bookshelf at 170px). Raising every short wrapper would
// stretch a compact player — Spotify asks for 152px, SoundCloud 166px — into an 800px block, and
// the Height menu's smallest preset leaves no way back. Matched on provider name, or on host for
// the responses that omit provider_name.
const RAW_EMBED_GROWING_PROVIDERS = ["Tally Forms", "Heyzine"];
const RAW_EMBED_GROWING_HOSTS = ["tally.so", "heyzine.com"];

const hostOf = (url: string): string | null => {
  try {
    return new URL(url).hostname.trim().toLowerCase();
  } catch {
    return null;
  }
};

const growsOnInsert = (data: IframelyEmbedData): boolean => {
  if (data.provider_name !== undefined && RAW_EMBED_GROWING_PROVIDERS.includes(data.provider_name)) return true;
  const host = hostOf(data.url);
  return host !== null && RAW_EMBED_GROWING_HOSTS.some((known) => host === known || host.endsWith(`.${known}`));
};

// Iframely has no live frame for a Heyzine shelf — a library of flipbooks — and answers with its own
// preview card, so the frame is built here pointing at the shelf page. Heyzine serves the same shelf at
// /shelf/<id>.html and at its canonical named form /shelf/<name>; every other lookup keeps iframely's html.
const HEYZINE_SHELF_PATH = /^\/shelf\/[\w-]+(?:\.html)?$/u;

export const heyzineShelfUrl = (raw: string): string | null => {
  try {
    const url = new URL(raw.trim());
    if (url.protocol !== "https:" || url.hostname.toLowerCase() !== "heyzine.com") return null;
    return HEYZINE_SHELF_PATH.test(url.pathname) ? `https://heyzine.com${url.pathname}` : null;
  } catch {
    return null;
  }
};

const shelfEmbedHtml = (shelfUrl: string): string =>
  '<div style="left: 0; width: 100%; height: ' +
  `${DEFAULT_RAW_EMBED_HEIGHT}px; position: relative;">` +
  `<iframe src="${shelfUrl}" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen></iframe>` +
  "</div>";

// Any other provider keeps the height iframely (or the seller, from the menu) chose for it.
const insertedRawEmbedHtml = (data: IframelyEmbedData): string => {
  const shelfUrl = heyzineShelfUrl(data.url);
  if (shelfUrl !== null) return shelfEmbedHtml(shelfUrl);
  if (!growsOnInsert(data)) return data.html;
  const declaredHeight = rawEmbedHeight(data.html);
  if (declaredHeight === null || declaredHeight >= DEFAULT_RAW_EMBED_HEIGHT) return data.html;
  return resizedRawEmbedHtml(data.html, DEFAULT_RAW_EMBED_HEIGHT);
};

const VideoEmbed = Extension.create({
  name: "videoEmbed",
  menuItem: (_editor, onOpen) => (
    <MenuItem name="Insert video" icon={<Video className="size-5" />} onClick={() => onOpen?.()} />
  ),
});

const renderRawDOM = (editor: Editor, node: ProseMirrorNode) =>
  DOMSerializer.fromSchema(editor.schema).serializeNode(node);

const RawNodeView = ({ editor, node, getPos, selected }: NodeViewProps) => {
  const dom = React.useMemo(() => renderRawDOM(editor, node), [editor, node]);
  const html = assertString(node.attrs.html);
  const declaredHeight = rawEmbedHeight(html);
  const wrapper = embedHeightWrapper(new DOMParser().parseFromString(html, "text/html"));
  const originalHeight = EMBED_HEIGHT_PX.exec(wrapper?.getAttribute("data-original-height") ?? "");
  const providerHeight = originalHeight && Number(originalHeight[1]) > 0 ? Number(originalHeight[1]) : null;
  // The provider's own height stays on the menu, so growing an embed is always reversible.
  const heightOptions =
    declaredHeight === null
      ? []
      : [
          ...new Set([
            declaredHeight,
            ...(providerHeight === null ? [] : [providerHeight]),
            ...RAW_EMBED_HEIGHT_OPTIONS,
          ]),
        ].sort((left, right) => left - right);
  const heightActions =
    heightOptions.length === 0
      ? []
      : [
          {
            item: () => (
              <>
                <RowResize className="size-5" />
                <span>Height</span>
              </>
            ),
            menu: (close: () => void) => (
              <>
                {heightOptions.map((height) => (
                  <MenuListItem
                    key={height}
                    onClick={() => {
                      editor
                        .chain()
                        .focus()
                        .updateAttributes("raw", { html: resizedRawEmbedHtml(html, height) })
                        .run();
                      close();
                    }}
                  >
                    <span>{`${height} px`}</span>
                  </MenuListItem>
                ))}
              </>
            ),
          },
        ];
  return (
    <NodeActionsWrapper selected={selected} asChild>
      <NodeViewWrapper contentEditable={false}>
        <NodeActionsMenu editor={editor} getPos={getPos} actions={heightActions} />
        {/* The iframe swallows clicks; without this the block can never be selected. */}
        <div
          className="tiptap__raw [&_iframe]:pointer-events-none"
          dangerouslySetInnerHTML={{ __html: dom instanceof Element ? dom.innerHTML : "" }}
        />
      </NodeViewWrapper>
    </NodeActionsWrapper>
  );
};

export const Raw = TiptapNode.create({
  name: "raw",
  inline: () => false,
  group: () => "block",
  draggable: true,
  addNodeView: () => {
    const renderEditable = ReactNodeViewRenderer(RawNodeView);
    // Read-only editors render the same DOM as the saved HTML.
    return (props) =>
      props.editor.isEditable ? renderEditable(props) : { dom: renderRawDOM(props.editor, props.node) };
  },
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
    const processedHtml = sanitizeHtml(assertString(HTMLAttributes.html));
    doc.innerHTML = processedHtml;
    if (HTMLAttributes.title) doc.setAttribute("data-title", assertString(HTMLAttributes.title));
    if (HTMLAttributes.url) doc.setAttribute("data-url", assertString(HTMLAttributes.url));
    if (HTMLAttributes.thumbnail) doc.setAttribute("data-thumbnail", assertString(HTMLAttributes.thumbnail));
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
type IframelyEmbedData = {
  html: string;
  title: string;
  url: string;
  // Iframely omits provider metadata for some rich embeds (Heyzine shelves among them); the html
  // it returns is still the whole embed, so only the fields we actually render are required.
  provider_name?: string;
  thumbnail_url?: string;
};

const isIframelyEmbedData = (data: unknown): data is IframelyEmbedData =>
  isRecord(data) &&
  isString(data.html) &&
  isString(data.title) &&
  isString(data.url) &&
  (data.provider_name === undefined || isString(data.provider_name)) &&
  (data.thumbnail_url === undefined || isString(data.thumbnail_url));

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

// Iframely caches each lookup against the exact URL string it was asked for, so a spelling whose
// lookup once failed keeps returning that failure: ask distinct spellings, in order, until one
// comes back usable. A healthy video stores its embed against the first spelling.
const YOUTUBE_EMBED_SPELLINGS: { url: (id: string) => string; startParam: "t" | "start" }[] = [
  { url: (id) => `https://www.youtube.com/watch?v=${id}`, startParam: "t" },
  { url: (id) => `https://www.youtube.com/embed/${id}`, startParam: "start" },
  { url: (id) => `https://youtu.be/${id}`, startParam: "t" },
  { url: (id) => `https://www.youtube-nocookie.com/embed/${id}`, startParam: "start" },
  { url: (id) => `https://m.youtube.com/watch?v=${id}`, startParam: "t" },
];

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
  const candidates = YOUTUBE_EMBED_SPELLINGS.map(({ url, startParam }) => {
    const candidate = new URL(url(id));
    if (start && startSeconds !== null) {
      candidate.searchParams.set(startParam, startParam === "t" ? start : String(startSeconds));
    }
    return candidate.toString();
  });
  // The string the seller pasted is the one spelling the generated list cannot produce when it
  // carries a parameter, and iframely keys its cached failure on the exact string: keep it last.
  const pasted = parsed.toString();
  return candidates.includes(pasted) ? candidates : [...candidates, pasted];
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
                  if (isIframelyEmbedData(data)) break;
                }
                if (isIframelyEmbedData(data)) {
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
  const { provider_name } = data;
  if (
    "insertMediaEmbed" in editor.commands &&
    provider_name !== undefined &&
    MEDIA_EMBED_SUPPORTING_PROVIDERS.includes(provider_name)
  ) {
    const responseHTML = new DOMParser().parseFromString(data.html, "text/html");
    const iframe = responseHTML.querySelector("iframe");
    const html = iframe ? iframe.outerHTML : data.html;
    editor.chain().focus().insertMediaEmbed({ html, title: data.title, url: data.url }).run();
  } else {
    editor
      .chain()
      .focus()
      .setRaw({
        html: insertedRawEmbedHtml(data),
        title: data.title,
        url: data.url,
        thumbnail: data.thumbnail_url,
      })
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
            dangerouslySetInnerHTML={{ __html: sanitizeHtml(assertString(node.attrs.html)) }}
          />
          <RowContent className="content">
            <PlayCircle pack="filled" className="type-icon size-5" />
            <div>
              <h4 className="truncate">{node.attrs.title}</h4>
              {node.attrs.url ? (
                <div className="truncate">
                  <a href={assertString(node.attrs.url)} target="_blank" rel="noreferrer">
                    {node.attrs.url}
                  </a>
                </div>
              ) : null}
            </div>
          </RowContent>
          {editor.isEditable ? (
            <RowActions>
              <Button size="sm" color="danger" outline onClick={deleteNode}>
                <Trash className="size-5" />
                Remove
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
