import { Editor, Content, createDocument, isList } from "@tiptap/core";
import Placeholder from "@tiptap/extension-placeholder";
import Underline from "@tiptap/extension-underline";
import { redoDepth, undoDepth } from "@tiptap/pm/history";
import { DOMSerializer } from "@tiptap/pm/model";
import { EditorState, Selection } from "@tiptap/pm/state";
import { EditorView } from "@tiptap/pm/view";
import { EditorContent, useEditor, Extensions } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import cx from "classnames";
import partition from "lodash/partition";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Icon } from "$app/components/Icons";
import { Popover, Props as PopoverProps } from "$app/components/Popover";
import { Separator } from "$app/components/Separator";
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";
import { CodeBlock } from "$app/components/TiptapExtensions/CodeBlock";
import { Image, uploadImages } from "$app/components/TiptapExtensions/Image";
import { Link, Button as TiptapButton } from "$app/components/TiptapExtensions/Link";
import { ReviewCard } from "$app/components/TiptapExtensions/ReviewCard";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { Product, ProductOption, UpsellSelectModal } from "$app/components/UpsellSelectModal";
import { WithTooltip } from "$app/components/WithTooltip";

import { Raw } from "./TiptapExtensions/MediaEmbed";

export const getInsertAtFromSelection = ({ $head, anchor, empty, from }: Selection): number => {
  let insertAt = from;
  // If caret is not at the beginning of the editor and on an empty line, insert
  // content before the caret to avoid an empty row before the inserted content
  if (anchor > 0 && ((empty && $head.parent.content.size === 0) || $head.parentOffset === 0)) insertAt -= 1;
  return insertAt;
};

export type ImageUploadSettings = {
  allowedExtensions: string[];
  onUpload: (file: File, src?: string) => Promise<string> | undefined;
  isUploading?: boolean;
};

const ToolbarTooltipContext = React.createContext<null | [boolean, (show: boolean) => void]>(null);
export const ImageUploadSettingsContext = React.createContext<null | ImageUploadSettings>(null);
export const useImageUploadSettings = () => React.useContext(ImageUploadSettingsContext);

const TOOLBAR_TOOLTIP_DEFAULT_DELAY = 800; // in milliseconds

const MenuItemTooltip = ({ tip, children }: { tip: string; children: React.ReactNode }) => {
  const [showTooltip, setShowTooltip] = assertDefined(React.useContext(ToolbarTooltipContext));

  const hoverTimeoutRef = React.useRef<ReturnType<typeof setTimeout>>();
  const onMouseEnter = () => {
    if (!showTooltip) {
      hoverTimeoutRef.current = setTimeout(() => setShowTooltip(true), TOOLBAR_TOOLTIP_DEFAULT_DELAY);
    }
  };
  const onMouseLeave = () => {
    if (hoverTimeoutRef.current) {
      clearTimeout(hoverTimeoutRef.current);
      hoverTimeoutRef.current = undefined;
    }
  };

  return (
    <WithTooltip position="bottom" tip={showTooltip ? tip : null}>
      <span onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
        {children}
      </span>
    </WithTooltip>
  );
};

export const MenuItem = ({
  name,
  icon,
  active,
  disabled,
  onClick,
}: {
  name: string;
  icon: IconName;
  active?: boolean;
  disabled?: boolean;
  onClick?: () => void;
}) => (
  <MenuItemTooltip tip={name}>
    <button
      type="button"
      className="toolbar-item"
      aria-pressed={active}
      disabled={disabled}
      aria-label={name}
      onClick={onClick}
    >
      <Icon name={icon} />
    </button>
  </MenuItemTooltip>
);

export const PopoverMenuItem = ({
  name,
  icon,
  active,
  ...props
}: { name: string; icon: IconName; active?: boolean } & Pick<PopoverProps, "children"> & Partial<PopoverProps>) => (
  <Popover
    aria-label={name}
    trigger={
      <MenuItemTooltip tip={name}>
        <div className={cx("toolbar-item", active)}>
          <Icon name={icon} />
        </div>
      </MenuItemTooltip>
    }
    {...props}
  />
);

declare module "@tiptap/core" {
  type MenuItemOptions = {
    menuItem?: (editor: Editor) => React.ReactNode;
    submenu?: { menu: "insert"; item: (editor: Editor) => React.ReactNode };
  };
  /* eslint-disable */
  interface NodeConfig<Options, Storage> extends MenuItemOptions {}
  interface MarkConfig<Options, Storage> extends MenuItemOptions {}
  interface ExtensionConfig<Options, Storage> extends MenuItemOptions {}
  /* eslint-enable */
}

export const validateUrl = (url?: string) => {
  if (!url) return false;

  url = url.trim();

  // Fix the URL if it starts with an invalid protocol string that is accidentally mistyped as `http:/example.com`, `https//example.com`, etc.
  if (/^https?:?[/]{0,2}.*/iu.test(url)) url = url.replace(/^https?:?[/]{0,2}/iu, "https://");

  // Add a protocol to the URL if it doesn't have one.
  if (!/^https?:\/\//iu.test(url)) url = `https://${url}`;

  try {
    return new URL(url).toString();
  } catch {
    return false;
  }
};

export const baseEditorOptions = (extensions: Extensions) => ({
  parseOptions: { preserveWhitespace: true },
  injectCSS: false,
  extensions: [
    StarterKit.configure({
      codeBlock: false,
      dropcursor: { color: "rgb(var(--accent))", width: 4, class: "drop-cursor" },
    }),
    Underline,
    Link,
    TiptapButton,
    Image,
    Raw,
    CodeBlock,
    ReviewCard,
  ]
    .filter((e) => !extensions.some((ex) => ex.name === e.name))
    .concat(extensions),
});

export const serializeEditorContentToHTML = (editor: Editor) => {
  const fragment = DOMSerializer.fromSchema(editor.schema).serializeFragment(editor.state.doc.content);
  for (const empty of fragment.querySelectorAll("p:not(.figcaption):empty, h2:empty, h3:empty, h4:empty")) {
    empty.innerHTML = "<br>";
  }
  for (const listItem of fragment.querySelectorAll("li")) {
    listItem.innerHTML = listItem.innerHTML.replace(/<\/?p>/gu, "");
  }
  for (const element of fragment.querySelectorAll("[src], [href], [data], [ping]"))
    for (const attr of ["src", "href", "data", "ping"])
      if (element.getAttribute(attr)?.startsWith("data:")) element.remove();
  const container = document.createElement("div");
  container.appendChild(fragment);
  return container.innerHTML;
};

export const useRichTextEditor = ({
  placeholder,
  initialValue,
  ariaLabel,
  id,
  className,
  editable = true,
  extensions = [],
  onChange,
  onCreate,
  onInputNonImageFiles,
}: {
  ariaLabel?: string | undefined;
  id?: string | undefined;
  className?: string | undefined;
  placeholder?: string | undefined;
  initialValue: Content;
  editable?: boolean | undefined;
  extensions?: Extensions | undefined;
  onChange?: ((newValue: string) => void) | undefined;
  onCreate?: ((editor: Editor) => void) | undefined;
  onInputNonImageFiles?: (files: File[]) => void;
}) => {
  const onUpdate = (editor: Editor) => {
    if (!onChange) return;

    onChange(serializeEditorContentToHTML(editor));
  };
  function walk(node: Element, moveBlocks?: { target: Node; before: Node | null }) {
    // cloning the array here as we modify it during iteration
    for (const child of [...node.children]) {
      if (/^(p|h\d|figure|div)$/iu.test(child.tagName) && moveBlocks) {
        child.remove();
        moveBlocks.target.insertBefore(child, moveBlocks.before);
      }
      walk(child, /^(p|h\d)$/iu.test(child.tagName) ? { target: node, before: child.nextSibling } : undefined);
    }
  }
  const content = React.useMemo(() => {
    if (!SSR && typeof initialValue === "string") {
      const dom = document.createElement("div");
      dom.innerHTML = initialValue;
      walk(dom);
      return dom.innerHTML.replace("<br></", "</");
    }

    return initialValue;
  }, [initialValue]);
  const imageSettings = useImageUploadSettings();
  const uploadFiles = ({ view, files }: { view: EditorView; files: File[] }) => {
    const [images, nonImages] = partition(files, (file) => file.type.startsWith("image"));
    onInputNonImageFiles?.(nonImages);
    uploadImages({ view, files: images, imageSettings });
  };

  const editor = useEditor({
    ...baseEditorOptions([...extensions, ...(placeholder ? [Placeholder.configure({ placeholder })] : []), UpsellCard]),
    immediatelyRender: false,
    editable,
    editorProps: {
      attributes: {
        ...(className ? { class: className } : {}),
        ...(ariaLabel ? { "aria-label": ariaLabel } : {}),
        ...(id ? { id } : {}),
      },
      handleDOMEvents: {
        paste(view, event: Event) {
          if (!(event instanceof ClipboardEvent)) return false;
          const files = [...(event.clipboardData?.files ?? [])];
          if (!files.length) return false;
          uploadFiles({ view, files });
          event.preventDefault();
          return true;
        },
        drop(view, event: Event) {
          if (!(event instanceof DragEvent)) return false;
          const files = [...(event.dataTransfer?.files ?? [])];
          if (!files.length) return false;
          const insertAt = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos;
          if (insertAt) {
            const transaction = view.state.tr;
            view.dispatch(transaction.setSelection(Selection.near(transaction.doc.resolve(insertAt))));
          }
          uploadFiles({ view, files });
          event.preventDefault();
          return true;
        },
      },
    },
    content,
    onUpdate: ({ editor }) => onUpdate(editor),
    onCreate: ({ editor }) => onCreate?.(editor),
  });

  React.useEffect(() => editor?.setOptions({ editable }), [editable]);

  React.useEffect(
    () =>
      queueMicrotask(() => {
        // discard any history from before content was reset
        editor?.view.updateState(
          EditorState.create({
            doc: createDocument(content, editor.state.schema),
            schema: editor.schema,
            plugins: editor.state.plugins,
          }),
        );
      }),
    [content],
  );

  return editor ?? null;
};

export const RichTextEditorToolbar = ({
  editor,
  custom,
  productId,
  className,
}: {
  custom?: React.ReactNode;
  editor: Editor;
  productId?: string;
  className?: string;
}) => {
  const showTooltipState = React.useState(false);
  const [_, setShowTooltip] = showTooltipState;
  const [_renderedAt, setRenderedAt] = React.useState(Date.now());

  const [isUpsellModalOpen, setIsUpsellModalOpen] = React.useState(false);
  const [isReviewModalOpen, setIsReviewModalOpen] = React.useState(false);

  const handleUpsellInsert = (product: Product, variant: ProductOption | null, discount: InputtedDiscount | null) => {
    editor
      .chain()
      .focus()
      .insertContent({
        type: "upsellCard",
        attrs: {
          productId: product.id,
          variantId: variant?.id,
          discount: discount
            ? discount.type === "cents"
              ? { type: "fixed", cents: discount.value ?? 0 }
              : { type: "percent", percents: discount.value ?? 0 }
            : null,
        },
      })
      .run();
    setIsUpsellModalOpen(false);
  };

  function handleReviewInsert(reviewIds: string[]) {
    for (const reviewId of reviewIds) {
      editor.chain().focus().insertReviewCard({ reviewId }).run();
    }
    setIsReviewModalOpen(false);
  }

  React.useEffect(() => {
    // This component is only reliably re-rendered when the content changes,
    // however toggling marks or moving the selection can also affect what buttons should be active.
    // This manually re-renders the component in these cases.
    // See also https://github.com/gumroad/web/pull/26370/files#r1273868758
    const handleTransaction = () => setRenderedAt(Date.now());
    editor.on("transaction", handleTransaction);
    return () => void editor.off("transaction", handleTransaction);
  }, [editor]);

  const textFormatOptions: { name: string; icon: IconName; type: string; attrs?: object }[] = [
    { name: "Text", icon: "fonts", type: "paragraph" },
    { name: "Header", icon: "h1", type: "heading", attrs: { level: 1 } },
    { name: "Title", icon: "h2", type: "heading", attrs: { level: 2 } },
    { name: "Subtitle", icon: "h3", type: "heading", attrs: { level: 3 } },
    { name: "Bulleted list", icon: "unordered-list", type: "bulletList" },
    { name: "Numbered list", icon: "ordered-list", type: "orderedList" },
    { name: "Code block", icon: "code", type: "codeBlock" },
  ];
  const activeFormatOption = [...textFormatOptions]
    .reverse()
    .find((option) => editor.isActive(option.type, option.attrs));
  const insertMenuItems = editor.extensionManager.extensions.filter(
    (extension) => extension.config.submenu?.menu === "insert",
  );
  const dividerExtension = editor.extensionManager.extensions.find((extension) => extension.name === "horizontalRule");
  if (dividerExtension) insertMenuItems.push(dividerExtension);
  const topMenuItems = editor.extensionManager.extensions.filter(
    (extension) => extension.config.menuItem && !extension.config.submenu,
  );
  if (insertMenuItems.length < 2) topMenuItems.push(...insertMenuItems);

  return (
    <ToolbarTooltipContext.Provider value={showTooltipState}>
      <div
        role="toolbar"
        className={cx("rich-text-editor-toolbar", className)}
        onMouseLeave={() => setShowTooltip(false)}
      >
        <Popover
          aria-label="Text formats"
          trigger={
            <div className="toolbar-item">
              {activeFormatOption?.name ?? "Text"} <Icon name="outline-cheveron-down" />
            </div>
          }
        >
          {(close) => (
            <ul role="menu">
              {textFormatOptions.map((option) => (
                <li
                  key={option.name}
                  role="menuitemradio"
                  aria-checked={option === activeFormatOption}
                  onClick={() => {
                    const commands = editor.chain();
                    if (isList(option.type, editor.extensionManager.extensions))
                      commands.toggleList(option.type, "listItem", false, option.attrs);
                    else commands.toggleNode(option.type, "paragraph", option.attrs);
                    commands.focus().run();
                    close();
                  }}
                >
                  <Icon name={option.icon} />
                  <span>{option.name}</span>
                </li>
              ))}
            </ul>
          )}
        </Popover>
        <Separator aria-orientation="vertical" />
        <MenuItem
          name="Bold"
          icon="bold"
          active={editor.isActive("bold")}
          onClick={() => editor.chain().focus().toggleBold().run()}
        />
        <MenuItem
          name="Italic"
          icon="italic"
          active={editor.isActive("italic")}
          onClick={() => editor.chain().focus().toggleItalic().run()}
        />
        <MenuItem
          name="Underline"
          icon="underline"
          active={editor.isActive("underline")}
          onClick={() => editor.chain().focus().toggleUnderline().run()}
        />
        <MenuItem
          name="Strikethrough"
          icon="strikethrough"
          active={editor.isActive("strike")}
          onClick={() => editor.chain().focus().toggleStrike().run()}
        />
        <MenuItem
          name="Quote"
          icon="quote"
          active={editor.isActive("blockquote")}
          onClick={() => editor.chain().focus().toggleBlockquote().run()}
        />
        <Separator aria-orientation="vertical" />
        {custom ?? (
          <>
            {topMenuItems.map((extension, i) => (
              <React.Fragment key={i}>
                {extension.name === "horizontalRule" ? (
                  <MenuItem
                    name="Divider"
                    icon="horizontal-rule"
                    onClick={() => editor.chain().focus().setHorizontalRule().run()}
                  />
                ) : (
                  extension.config.menuItem?.(editor)
                )}
              </React.Fragment>
            ))}

            {insertMenuItems.length > 1 ? (
              <>
                <Separator aria-orientation="vertical" />
                <Popover
                  trigger={
                    <div className="toolbar-item">
                      Insert <Icon name="outline-cheveron-down" />
                    </div>
                  }
                >
                  {(close) => (
                    <div role="menu" onClick={close}>
                      {insertMenuItems.map((item, i) => (
                        <React.Fragment key={i}>
                          {item.name === "horizontalRule" ? (
                            <div role="menuitem" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
                              <Icon name="horizontal-rule" />
                              <span>Divider</span>
                            </div>
                          ) : (
                            item.config.submenu?.item(editor)
                          )}
                        </React.Fragment>
                      ))}
                      <div role="menuitem" onClick={() => setIsUpsellModalOpen(true)}>
                        <Icon name="cart-plus" />
                        <span>Upsell</span>
                      </div>
                      {productId ? (
                        <div role="menuitem" onClick={() => setIsReviewModalOpen(true)}>
                          <Icon name="solid-star" />
                          <span>Reviews</span>
                        </div>
                      ) : null}
                    </div>
                  )}
                </Popover>
              </>
            ) : null}
          </>
        )}
        <div className="ml-auto flex">
          <MenuItem
            name="Undo last change"
            icon="undo"
            active={editor.isActive("undo")}
            disabled={undoDepth(editor.state) === 0}
            onClick={() => editor.chain().focus().undo().run()}
          />
          <MenuItem
            name="Redo last undone change"
            icon="redo"
            active={editor.isActive("redo")}
            disabled={redoDepth(editor.state) === 0}
            onClick={() => editor.chain().focus().redo().run()}
          />
        </div>
      </div>
      <UpsellSelectModal
        isOpen={isUpsellModalOpen}
        onClose={() => setIsUpsellModalOpen(false)}
        onInsert={handleUpsellInsert}
      />
      {productId ? (
        <TestimonialSelectModal
          isOpen={isReviewModalOpen}
          onClose={() => setIsReviewModalOpen(false)}
          onInsert={handleReviewInsert}
          productId={productId}
        />
      ) : null}
    </ToolbarTooltipContext.Provider>
  );
};

export const RichTextEditor = ({
  id,
  className,
  placeholder,
  initialValue,
  ariaLabel,
  onChange,
  onCreate,
  extensions,
}: {
  id?: string;
  className?: string;
  placeholder?: string;
  initialValue: Content;
  ariaLabel?: string;
  onChange?: (newValue: string) => void;
  onCreate?: (editor: Editor) => void;
  extensions?: Extensions;
}) => {
  const editor = useRichTextEditor({
    id,
    className,
    ariaLabel,
    placeholder,
    initialValue,
    onChange,
    onCreate,
    extensions,
  });

  return (
    <div className="rich-text-editor" data-gumroad-ignore>
      {editor ? <RichTextEditorToolbar editor={editor} /> : null}
      <EditorContent className="rich-text" editor={editor} />
    </div>
  );
};
