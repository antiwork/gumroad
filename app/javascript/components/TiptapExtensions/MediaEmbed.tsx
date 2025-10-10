import { Editor, Node as TiptapNode, Extension } from "@tiptap/core";
import { DOMOutputSpec } from "@tiptap/pm/model";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { createPortal } from "react-dom";
import { cast, is } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { sanitizeHtml } from "$app/utils/sanitize";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { MenuItem } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";

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
  menuItem: (editor) => (
    <WithDialog editor={editor} type="embed">
      <MenuItem name="Insert video" icon="embed" />
    </WithDialog>
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
    const processedHtml = sanitizeHtml(cast(HTMLAttributes.html));
    doc.innerHTML = processedHtml;
    if (HTMLAttributes.title) doc.setAttribute("data-title", cast(HTMLAttributes.title));
    if (HTMLAttributes.url) doc.setAttribute("data-url", cast(HTMLAttributes.url));
    if (HTMLAttributes.thumbnail) doc.setAttribute("data-thumbnail", cast(HTMLAttributes.thumbnail));
    const walk = (element: Element): DOMOutputSpec => {
      const attrs: Record<string, string> = {};
      for (const attr of element.attributes) attrs[attr.name] = attr.value;
      return [element.tagName, attrs, ...[...element.children].map(walk)];
    };
    return walk(doc);
  },
  menuItem: (editor) => (
    <WithDialog editor={editor} type="twitter">
      <MenuItem name="Insert post" icon="twitter" />
    </WithDialog>
  ),
  submenu: {
    menu: "insert",
    item: (editor) => (
      <WithDialog editor={editor} type="twitter">
        <div role="menuitem">
          <Icon name="twitter" />
          <span>Twitter post</span>
        </div>
      </WithDialog>
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
        <input
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
          className="button-group"
          style={{ alignSelf: "flex-end", gap: "var(--spacer-4)", marginTop: "var(--spacer-2)" }}
        >
          <Button onClick={onClose}>Cancel</Button>
          <Button
            color="primary"
            onClick={asyncVoid(async () => {
              if (!inputRef.current) {
                return;
              }
              const encoded = encodeURIComponent(inputRef.current.value);
              // omit_script forces iframely to return an <iframe> tag
              const iframelyUrl = `https://iframe.ly/api/oembed?iframe=1&api_key=6317bed3ca048a1a75d850&url=${encoded}&omit_script=1`;
              try {
                const data: unknown = await (await request({ method: "GET", url: iframelyUrl, accept: "json" })).json();
                if (is<IframelyEmbedData>(data)) {
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
      <fieldset>
        <legend>
          <label htmlFor={inputUid}>{type === "embed" ? "Video URL" : "Tweet URL"}</label>
        </legend>
        {horizontalLayout ? <div className="input-with-button">{fields}</div> : fields}
      </fieldset>
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

const WithDialog = ({
  editor,
  type,
  children,
}: {
  editor: Editor;
  type: "embed" | "twitter";
  children: React.ReactNode;
}) => {
  const [open, setOpen] = React.useState(false);
  return (
    <>
      {open
        ? // TODO (maya) remove this once popovers no longer use details
          createPortal(
            <Modal open onClose={() => setOpen(false)} title={`Insert ${type === "embed" ? "video" : "post"}`}>
              <EmbedMediaForm
                type={type}
                onEmbedReceived={(data) => {
                  insertMediaEmbed(editor, data);
                  setOpen(false);
                }}
                onClose={() => setOpen(false)}
              />
            </Modal>,
            document.body,
          )
        : null}
      <div onClick={() => setOpen(true)}>{children}</div>
    </>
  );
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
        <div className="embed">
          <div className="preview" dangerouslySetInnerHTML={{ __html: sanitizeHtml(cast(node.attrs.html)) }}></div>
          <div className="content">
            <Icon name="file-earmark-play-fill" className="type-icon" />
            <div>
              <h4 className="text-singleline">{node.attrs.title}</h4>
              {node.attrs.url ? (
                <div className="text-singleline">
                  <a href={cast(node.attrs.url)} target="_blank" rel="noreferrer">
                    {node.attrs.url}
                  </a>
                </div>
              ) : null}
            </div>
          </div>
          {editor.isEditable ? (
            <div className="actions">
              <Button color="danger" outline aria-label="Remove" onClick={deleteNode}>
                <Icon name="trash2" />
              </Button>
            </div>
          ) : null}
        </div>
      </NodeViewWrapper>
    ));
  },
  addCommands() {
    return {
      insertMediaEmbed: createInsertCommand("mediaEmbed"),
    };
  },
});
