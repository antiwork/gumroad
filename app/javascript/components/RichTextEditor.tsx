import {
  Bold,
  CartPlus,
  ChevronDown,
  Code,
  FontFamily,
  Heading1,
  Heading2,
  Heading3,
  Italic,
  ListOl,
  ListUl,
  Minus,
  QuoteLeftAlt,
  Redo,
  Star,
  Strikethrough,
  Underline as UnderlineIcon,
  Undo,
} from "@boxicons/react";
import { Content, createDocument, Editor, isList } from "@tiptap/core";
import Placeholder from "@tiptap/extension-placeholder";
import Underline from "@tiptap/extension-underline";
import { redoDepth, undoDepth } from "@tiptap/pm/history";
import { DOMSerializer } from "@tiptap/pm/model";
import { EditorState, Selection } from "@tiptap/pm/state";
import { EditorView } from "@tiptap/pm/view";
import { EditorContent, Extensions, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { partition } from "lodash-es";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";
import { CodeBlock } from "$app/components/TiptapExtensions/CodeBlock";
import { Image, uploadImages } from "$app/components/TiptapExtensions/Image";
import { Link, Button as TiptapButton } from "$app/components/TiptapExtensions/Link";
import { ReviewCard } from "$app/components/TiptapExtensions/ReviewCard";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { Menu as MenuContainer, MenuItem as MenuListItem, MenuItemRadio } from "$app/components/ui/Menu";
import { Product, ProductOption, UpsellSelectModal } from "$app/components/UpsellSelectModal";
import { Position, WithTooltip } from "$app/components/WithTooltip";

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
  maxFileSize?: number;
};

const ToolbarTooltipContext = React.createContext<null | [boolean, (show: boolean) => void]>(null);
export const ImageUploadSettingsContext = React.createContext<null | ImageUploadSettings>(null);
export const useImageUploadSettings = () => React.useContext(ImageUploadSettingsContext);

const TOOLBAR_TOOLTIP_DEFAULT_DELAY = 800; // in milliseconds

const MenuItemTooltip = ({
  tip,
  children,
  position = "bottom",
}: {
  tip: string;
  children: React.ReactNode;
  position?: Position | undefined;
}) => {
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
    <WithTooltip position={position} tip={showTooltip ? tip : null}>
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
  position,
}: {
  name: string;
  icon: React.ReactNode;
  active?: boolean;
  disabled?: boolean;
  onClick?: () => void;
  position?: Position | undefined;
}) => (
  <MenuItemTooltip tip={name} position={position}>
    <button
      type="button"
      className="cursor-pointer rounded px-2 py-1 all-unset hover:bg-active-bg aria-pressed:text-accent"
      aria-pressed={active}
      disabled={disabled}
      aria-label={name}
      onClick={onClick}
    >
      {icon}
    </button>
  </MenuItemTooltip>
);

export const PopoverMenuItem = ({
  name,
  icon,
  children,
}: {
  name: string;
  icon: React.ReactNode;
  children: React.ReactNode;
}) => (
  <Popover>
    <PopoverTrigger aria-label={name} className="all-unset">
      <MenuItemTooltip tip={name}>
        <div className="flex items-center gap-2 rounded px-2 py-1 hover:bg-active-bg">
          {icon}
          <span>{name}</span>
        </div>
      </MenuItemTooltip>
    </PopoverTrigger>
    <PopoverContent usePortal sideOffset={4} className="border-0 p-0 shadow-none">
      {children}
    </PopoverContent>
  </Popover>
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

  const content: Content = React.useMemo(() => {
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
        class: classNames(
          "focus-within:outline-none",
          editable && "min-h-full whitespace-break-spaces rounded-t-none",
          className,
        ),
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
  color = "primary",
  className,
}: {
  custom?: React.ReactNode;
  editor: Editor;
  productId?: string;
  color?: "primary" | "ghost";
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

  const textFormatOptions: { name: string; icon: React.ReactNode; type: string; attrs?: object }[] = [
    { name: "Text", icon: <FontFamily className="size-5" />, type: "paragraph" },
    { name: "Header", icon: <Heading1 className="size-5" />, type: "heading", attrs: { level: 1 } },
    { name: "Title", icon: <Heading2 className="size-5" />, type: "heading", attrs: { level: 2 } },
    { name: "Subtitle", icon: <Heading3 className="size-5" />, type: "heading", attrs: { level: 3 } },
    { name: "Bulleted list", icon: <ListUl className="size-5" />, type: "bulletList" },
    { name: "Numbered list", icon: <ListOl className="size-5" />, type: "orderedList" },
    { name: "Code block", icon: <Code className="size-5" />, type: "codeBlock" },
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
        className={classNames(
          "sticky top-0 z-1 flex flex-wrap gap-1 px-2 py-1 text-foreground",
          color === "ghost" ? "bg-background" : "bg-primary text-primary-foreground",
          className,
        )}
        style={
          color === "primary"
            ? {
                // Fix muted to work with the inverted background. This is necessary because muted is currently semitransparent,
                // but when we're fully in Tailwind we can remove the --gray-3 definition, make muted a solid color, and remove this.
                "--color-muted":
                  "color-mix(in srgb, var(--color-primary-foreground) calc(var(--gray-3) * 100%), transparent)",
              }
            : {}
        }
        onMouseLeave={() => setShowTooltip(false)}
      >
        <Popover>
          <PopoverTrigger aria-label="Text formats" className="rounded px-2 py-1 all-unset hover:bg-active-bg">
            {activeFormatOption?.name ?? "Text"} <ChevronDown className="size-5" />
          </PopoverTrigger>
          <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
            <MenuContainer>
              {textFormatOptions.map((option) => (
                <PopoverClose key={option.name} asChild>
                  <MenuItemRadio
                    checked={option === activeFormatOption}
                    aria-checked={option === activeFormatOption}
                    className="aria-checked:bg-active-bg"
                    onClick={() => {
                      const commands = editor.chain();
                      if (isList(option.type, editor.extensionManager.extensions))
                        commands.toggleList(option.type, "listItem", false, option.attrs);
                      else commands.toggleNode(option.type, "paragraph", option.attrs);
                      commands.focus().run();
                    }}
                  >
                    {option.icon}
                    <span>{option.name}</span>
                  </MenuItemRadio>
                </PopoverClose>
              ))}
            </MenuContainer>
          </PopoverContent>
        </Popover>
        <div
          role="separator"
          aria-orientation="vertical"
          className="m-2 hidden border-r border-solid border-muted sm:flex"
        />
        <MenuItem
          name="Bold"
          icon={<Bold className="size-5" />}
          active={editor.isActive("bold")}
          onClick={() => editor.chain().focus().toggleBold().run()}
        />
        <MenuItem
          name="Italic"
          icon={<Italic className="size-5" />}
          active={editor.isActive("italic")}
          onClick={() => editor.chain().focus().toggleItalic().run()}
        />
        <MenuItem
          name="Underline"
          icon={<UnderlineIcon className="size-5" />}
          active={editor.isActive("underline")}
          onClick={() => editor.chain().focus().toggleUnderline().run()}
        />
        <MenuItem
          name="Strikethrough"
          icon={<Strikethrough className="size-5" />}
          active={editor.isActive("strike")}
          onClick={() => editor.chain().focus().toggleStrike().run()}
        />
        <MenuItem
          name="Quote"
          icon={<QuoteLeftAlt pack="filled" className="size-5" />}
          active={editor.isActive("blockquote")}
          onClick={() => editor.chain().focus().toggleBlockquote().run()}
        />
        <div
          role="separator"
          aria-orientation="vertical"
          className="m-2 hidden border-r border-solid border-muted sm:flex"
        />
        {custom ?? (
          <>
            {topMenuItems.map((extension, i) => (
              <React.Fragment key={i}>
                {extension.name === "horizontalRule" ? (
                  <MenuItem
                    name="Divider"
                    icon={<Minus className="size-5" />}
                    onClick={() => editor.chain().focus().setHorizontalRule().run()}
                  />
                ) : (
                  extension.config.menuItem?.(editor)
                )}
              </React.Fragment>
            ))}

            {insertMenuItems.length > 1 ? (
              <>
                <div
                  role="separator"
                  aria-orientation="vertical"
                  className="m-2 hidden border-r border-muted sm:flex"
                />
                <Popover>
                  <PopoverTrigger className="rounded px-2 py-1 all-unset hover:bg-active-bg">
                    Insert <ChevronDown className="size-5" />
                  </PopoverTrigger>
                  <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                    <MenuContainer>
                      {insertMenuItems.map((item, i) => (
                        <React.Fragment key={i}>
                          {item.name === "horizontalRule" ? (
                            <PopoverClose asChild>
                              <MenuListItem onClick={() => editor.chain().focus().setHorizontalRule().run()}>
                                <Minus className="size-5" />
                                <span>Divider</span>
                              </MenuListItem>
                            </PopoverClose>
                          ) : (
                            <PopoverClose asChild>
                              <div>{item.config.submenu?.item(editor)}</div>
                            </PopoverClose>
                          )}
                        </React.Fragment>
                      ))}
                      <PopoverClose asChild>
                        <MenuListItem onClick={() => setIsUpsellModalOpen(true)}>
                          <CartPlus className="size-5" />
                          <span>Upsell</span>
                        </MenuListItem>
                      </PopoverClose>
                      {productId ? (
                        <PopoverClose asChild>
                          <MenuListItem onClick={() => setIsReviewModalOpen(true)}>
                            <Star pack="filled" className="size-5" />
                            <span>Reviews</span>
                          </MenuListItem>
                        </PopoverClose>
                      ) : null}
                    </MenuContainer>
                  </PopoverContent>
                </Popover>
              </>
            ) : null}
          </>
        )}
        <div className="ml-auto flex">
          <MenuItem
            name="Undo last change"
            icon={<Undo className="size-5" />}
            active={editor.isActive("undo")}
            disabled={undoDepth(editor.state) === 0}
            onClick={() => editor.chain().focus().undo().run()}
          />
          <MenuItem
            name="Redo last undone change"
            icon={<Redo className="size-5" />}
            active={editor.isActive("redo")}
            disabled={redoDepth(editor.state) === 0}
            onClick={() => editor.chain().focus().redo().run()}
            position="bottom-end"
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
    <div className="grid min-h-56 grid-rows-[max-content_1fr] rounded" data-gumroad-ignore>
      {editor ? (
        <RichTextEditorToolbar editor={editor} className="rounded-t rounded-b-none border border-b-0 border-border" />
      ) : null}
      <EditorContent className="rich-text" editor={editor} />
    </div>
  );
};
