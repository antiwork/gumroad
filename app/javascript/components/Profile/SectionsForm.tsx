import {
  ArrowDown,
  ArrowUp,
  Bold,
  Copy,
  Italic,
  Minus,
  Plus,
  QuoteLeftAlt,
  Redo,
  Strikethrough,
  Trash,
  Underline as UnderlineIcon,
  Undo,
} from "@boxicons/react";
import type { Editor } from "@tiptap/core";
import { redoDepth, undoDepth } from "@tiptap/pm/history";
import { EditorContent } from "@tiptap/react";
import { debounce, isEqual, sortBy } from "lodash-es";
import * as React from "react";
import typia from "typia";

import { updateProfileSettings } from "$app/data/profile_settings";
import { PROFILE_SORT_KEYS, type ProfileSortKey } from "$app/parsers/product";
import GuidGenerator from "$app/utils/guid_generator";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { SORT_BY_LABELS } from "$app/components/Product/CardGrid";
import { useTabs } from "$app/components/Profile";
import type { ProfileEditorProps, ProfileEditorState } from "$app/components/Profile/EditPage";
import { Section, useSectionImageUploadSettings } from "$app/components/Profile/EditSections";
import { ImageUploadSettingsContext, useRichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { uploadImages } from "$app/components/TiptapExtensions/Image";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Select } from "$app/components/ui/Select";

type ProfileSectionsFormState = ProfileEditorState & { selectedTabIndex: number };

export type ProfileSectionsFormProps = ProfileEditorProps & {
  onChange?: (state: ProfileSectionsFormState) => void;
  disabled?: boolean;
};

const SECTION_TYPE_LABELS: Record<Section["type"], string> = {
  SellerProfileProductsSection: "Products",
  SellerProfilePostsSection: "Posts",
  SellerProfileFeaturedProductSection: "Featured product",
  SellerProfileRichTextSection: "Rich text",
  SellerProfileSubscribeSection: "Subscribe",
  SellerProfileWishlistsSection: "Wishlists",
};

const SECTION_TYPE_OPTIONS: { id: Section["type"]; label: string }[] = [
  { id: "SellerProfileProductsSection", label: SECTION_TYPE_LABELS.SellerProfileProductsSection },
  { id: "SellerProfilePostsSection", label: SECTION_TYPE_LABELS.SellerProfilePostsSection },
  { id: "SellerProfileFeaturedProductSection", label: SECTION_TYPE_LABELS.SellerProfileFeaturedProductSection },
  { id: "SellerProfileRichTextSection", label: SECTION_TYPE_LABELS.SellerProfileRichTextSection },
  { id: "SellerProfileSubscribeSection", label: SECTION_TYPE_LABELS.SellerProfileSubscribeSection },
  { id: "SellerProfileWishlistsSection", label: SECTION_TYPE_LABELS.SellerProfileWishlistsSection },
];

const RICH_TEXT_FORMAT_OPTIONS = [
  { id: "paragraph", label: "Text" },
  { id: "heading-1", label: "Header" },
  { id: "heading-2", label: "Title" },
  { id: "heading-3", label: "Subtitle" },
  { id: "bullet-list", label: "Bulleted list" },
  { id: "ordered-list", label: "Numbered list" },
  { id: "code-block", label: "Code block" },
] as const;

type RichTextFormat = (typeof RICH_TEXT_FORMAT_OPTIONS)[number]["id"];

const tabsWithoutIds = (tabs: ReturnType<typeof useTabs>["tabs"]) => tabs.map(({ id: _id, ...tab }) => tab);

const parseRichTextFormat = (value: string) =>
  RICH_TEXT_FORMAT_OPTIONS.find((option) => option.id === value)?.id ?? null;

const parseSectionType = (value: string) => SECTION_TYPE_OPTIONS.find((option) => option.id === value)?.id ?? null;

const parseProfileSortKey = (value: string): ProfileSortKey | null =>
  PROFILE_SORT_KEYS.find((key) => key === value) ?? null;

const moveItem = <T,>(items: T[], index: number, direction: -1 | 1) => {
  const nextIndex = index + direction;
  if (index < 0 || nextIndex < 0 || nextIndex >= items.length) return items;
  const updated = [...items];
  const [item] = updated.splice(index, 1);
  if (item) updated.splice(nextIndex, 0, item);
  return updated;
};

const responseErrorMessage = async (response: Response) => {
  try {
    const json: unknown = await response.json();
    if (json && typeof json === "object" && "error" in json && typeof json.error === "string") return json.error;
  } catch {
    // Fall back to the generic response error below.
  }

  return undefined;
};

const assertResponseOk = async (response: Response) => {
  if (!response.ok) throw new ResponseError(await responseErrorMessage(response));
};

const SectionActions = ({
  index,
  count,
  onMove,
  onRemove,
  onCopyLink,
}: {
  index: number;
  count: number;
  onMove: (direction: -1 | 1) => void;
  onRemove: () => void;
  onCopyLink: () => void;
}) => (
  <div className="flex flex-wrap gap-2">
    <Button size="sm" onClick={() => onMove(-1)} disabled={index === 0} aria-label="Move section up">
      <ArrowUp className="size-4" />
      Move up
    </Button>
    <Button size="sm" onClick={() => onMove(1)} disabled={index === count - 1} aria-label="Move section down">
      <ArrowDown className="size-4" />
      Move down
    </Button>
    <Button size="sm" onClick={onCopyLink}>
      <Copy className="size-4" />
      Copy link
    </Button>
    <Button size="sm" color="danger" onClick={onRemove}>
      <Trash className="size-4" />
      Remove
    </Button>
  </div>
);

const OptionCheckboxRow = ({
  name,
  checked,
  canMove,
  isFirst,
  isLast,
  onToggle,
  onMove,
}: {
  name: string;
  checked: boolean;
  canMove?: boolean;
  isFirst?: boolean;
  isLast?: boolean;
  onToggle: () => void;
  onMove?: (direction: -1 | 1) => void;
}) => {
  const checkboxId = React.useId();
  return (
    <Row role="listitem">
      <RowContent asChild>
        <Label htmlFor={checkboxId}>
          <Checkbox id={checkboxId} checked={checked} onChange={onToggle} />
          <span className="truncate">{name}</span>
        </Label>
      </RowContent>
      {canMove && checked && onMove ? (
        <RowActions>
          <Button size="sm" onClick={() => onMove(-1)} disabled={isFirst} aria-label={`Move ${name} up`}>
            <ArrowUp className="size-4" />
            Move up
          </Button>
          <Button size="sm" onClick={() => onMove(1)} disabled={isLast} aria-label={`Move ${name} down`}>
            <ArrowDown className="size-4" />
            Move down
          </Button>
        </RowActions>
      ) : null}
    </Row>
  );
};

const useSaveSection = (initialSection: Section) => {
  const [savedSection, setSavedSection] = React.useState(initialSection);
  React.useEffect(() => setSavedSection(initialSection), [initialSection.id]);

  return async (section: Section) => {
    if (isEqual(savedSection, section)) return;
    try {
      const response = await request({
        method: "PATCH",
        url: Routes.profile_section_path(section.id),
        data: section,
        accept: "json",
      });
      await assertResponseOk(response);
      showAlert("Changes saved!", "success");
      setSavedSection(section);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };
};

const SectionForm = ({
  section,
  index,
  count,
  state,
  updateSection,
  moveSection,
  removeSection,
}: {
  section: Section;
  index: number;
  count: number;
  state: ProfileEditorProps;
  updateSection: (section: Section) => void;
  moveSection: (sectionId: string, direction: -1 | 1) => void;
  removeSection: (sectionId: string) => void;
}) => {
  const saveSection = useSaveSection(section);
  const uid = React.useId();
  const sectionTitle = section.header || SECTION_TYPE_LABELS[section.type];
  const commit = (updated: Section) => {
    updateSection(updated);
    void saveSection(updated);
  };
  const update = (updated: Section) => updateSection(updated);
  const copyLink = () => {
    try {
      void navigator.clipboard
        .writeText(new URL(`?section=${section.id}#${section.id}`, window.location.href).toString())
        .then(() => showAlert("Section link copied!", "success"))
        .catch(() => showAlert("Clipboard is not available.", "error"));
    } catch {
      showAlert("Clipboard is not available.", "error");
    }
  };

  return (
    <section className="grid gap-6 border-t border-border py-6" aria-label={`${sectionTitle} section settings`}>
      <header className="grid gap-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3>{sectionTitle}</h3>
            <div className="text-muted">{SECTION_TYPE_LABELS[section.type]}</div>
          </div>
          <SectionActions
            index={index}
            count={count}
            onMove={(direction) => moveSection(section.id, direction)}
            onRemove={() => removeSection(section.id)}
            onCopyLink={copyLink}
          />
        </div>
        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-header`}>Section name</Label>
          </FieldsetTitle>
          <Input
            id={`${uid}-header`}
            value={section.header}
            onChange={(evt) => update({ ...section, header: evt.target.value })}
            onBlur={(evt) => commit({ ...section, header: evt.target.value })}
          />
        </Fieldset>
        <Label className="inline-flex items-center gap-2">
          <Checkbox
            checked={!section.hide_header}
            onChange={() => commit({ ...section, hide_header: !section.hide_header })}
          />
          Show section name
        </Label>
      </header>

      {section.type === "SellerProfileProductsSection" ? (
        <ProductsSectionFields section={section} state={state} commit={commit} />
      ) : section.type === "SellerProfilePostsSection" ? (
        <PostsSectionFields section={section} state={state} commit={commit} />
      ) : section.type === "SellerProfileRichTextSection" ? (
        <RichTextSectionFields section={section} commit={commit} />
      ) : section.type === "SellerProfileSubscribeSection" ? (
        <SubscribeSectionFields section={section} update={update} commit={commit} />
      ) : section.type === "SellerProfileFeaturedProductSection" ? (
        <FeaturedProductSectionFields section={section} state={state} commit={commit} />
      ) : (
        <WishlistsSectionFields section={section} state={state} commit={commit} />
      )}
    </section>
  );
};

const ProductsSectionFields = ({
  section,
  state,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfileProductsSection" }>;
  state: ProfileEditorProps;
  commit: (section: Section) => void;
}) => {
  const orderedProducts = sortBy(state.products, (product) => {
    const index = section.shown_products.indexOf(product.id);
    return index < 0 ? Infinity : index;
  });
  const selectedProducts = orderedProducts.filter((product) => section.shown_products.includes(product.id));
  const toggleProduct = (id: string) =>
    commit({
      ...section,
      shown_products: section.shown_products.includes(id)
        ? section.shown_products.filter((productId) => productId !== id)
        : [...section.shown_products, id],
    });
  const moveProduct = (id: string, direction: -1 | 1) => {
    const index = section.shown_products.indexOf(id);
    commit({ ...section, shown_products: moveItem(section.shown_products, index, direction) });
  };

  return (
    <div className="grid gap-4">
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={`${section.id}-default-sort`}>Default sort order</Label>
        </FieldsetTitle>
        <Select
          id={`${section.id}-default-sort`}
          value={section.default_product_sort}
          onChange={(evt) => {
            const default_product_sort = parseProfileSortKey(evt.target.value);
            if (default_product_sort) commit({ ...section, default_product_sort });
          }}
        >
          {PROFILE_SORT_KEYS.map((key) => (
            <option key={key} value={key}>
              {SORT_BY_LABELS[key]}
            </option>
          ))}
        </Select>
      </Fieldset>
      <Label className="inline-flex items-center gap-2">
        <Checkbox
          checked={section.show_filters}
          onChange={() => commit({ ...section, show_filters: !section.show_filters })}
        />
        Show product filters
      </Label>
      <Label className="inline-flex items-center gap-2">
        <Checkbox
          checked={section.add_new_products}
          onChange={() => commit({ ...section, add_new_products: !section.add_new_products })}
        />
        Add new products by default
      </Label>
      <Fieldset>
        <FieldsetTitle>Products</FieldsetTitle>
        {orderedProducts.length ? (
          <Rows role="list" aria-label="Products">
            {orderedProducts.map((product) => {
              const selectedIndex = selectedProducts.findIndex((selected) => selected.id === product.id);
              return (
                <OptionCheckboxRow
                  key={product.id}
                  name={product.name}
                  checked={section.shown_products.includes(product.id)}
                  canMove={section.default_product_sort === "page_layout"}
                  isFirst={selectedIndex === 0}
                  isLast={selectedIndex === selectedProducts.length - 1}
                  onToggle={() => toggleProduct(product.id)}
                  onMove={(direction) => moveProduct(product.id, direction)}
                />
              );
            })}
          </Rows>
        ) : (
          <p>No products available.</p>
        )}
      </Fieldset>
    </div>
  );
};

const PostsSectionFields = ({
  section,
  state,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfilePostsSection" }>;
  state: ProfileEditorProps;
  commit: (section: Section) => void;
}) => {
  const togglePost = (id: string) =>
    commit({
      ...section,
      shown_posts: section.shown_posts.includes(id)
        ? section.shown_posts.filter((postId) => postId !== id)
        : [...section.shown_posts, id],
    });

  return (
    <Fieldset>
      <FieldsetTitle>Posts</FieldsetTitle>
      {state.posts.length ? (
        <Rows role="list" aria-label="Posts">
          {state.posts.map((post) => (
            <OptionCheckboxRow
              key={post.id}
              name={post.name}
              checked={section.shown_posts.includes(post.id)}
              onToggle={() => togglePost(post.id)}
            />
          ))}
        </Rows>
      ) : (
        <p>No published profile posts available.</p>
      )}
    </Fieldset>
  );
};

const RichTextSectionFields = ({
  section,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfileRichTextSection" }>;
  commit: (section: Section) => void;
}) => {
  const [initialValue] = React.useState(section.text);
  const editor = useRichTextEditor({ initialValue, placeholder: "Enter text here", editable: true });
  const sectionRef = React.useRef(section);
  React.useEffect(() => {
    sectionRef.current = section;
  }, [section]);
  const imageUploadSettings = useSectionImageUploadSettings();
  const isUploadingRef = React.useRef(imageUploadSettings.isUploading);
  React.useEffect(() => {
    isUploadingRef.current = imageUploadSettings.isUploading;
  }, [imageUploadSettings.isUploading]);

  React.useEffect(() => {
    if (!editor) return;
    const save = () => {
      if (isUploadingRef.current) return;
      const updated = { ...sectionRef.current, text: editor.getJSON() };
      commit(updated);
    };
    const debouncedSave = debounce(save, 2000);
    editor.on("blur", save);
    editor.on("update", debouncedSave);
    return () => {
      editor.off("blur", save);
      editor.off("update", debouncedSave);
    };
  }, [editor]);

  return (
    <Fieldset>
      <FieldsetTitle>Text</FieldsetTitle>
      <ImageUploadSettingsContext.Provider value={imageUploadSettings}>
        {editor ? <RichTextControls editor={editor} imageUploadSettings={imageUploadSettings} /> : null}
        <EditorContent editor={editor} className="rich-text rounded border border-border p-4" />
      </ImageUploadSettingsContext.Provider>
    </Fieldset>
  );
};

const RichTextControls = ({
  editor,
  imageUploadSettings,
}: {
  editor: Editor;
  imageUploadSettings: ReturnType<typeof useSectionImageUploadSettings>;
}) => {
  const [, rerender] = React.useReducer((count: number) => count + 1, 0);
  const imageInputId = React.useId();

  React.useEffect(() => {
    const handleTransaction = () => rerender();
    editor.on("transaction", handleTransaction);
    return () => void editor.off("transaction", handleTransaction);
  }, [editor]);

  const activeFormat: RichTextFormat = editor.isActive("heading", { level: 1 })
    ? "heading-1"
    : editor.isActive("heading", { level: 2 })
      ? "heading-2"
      : editor.isActive("heading", { level: 3 })
        ? "heading-3"
        : editor.isActive("bulletList")
          ? "bullet-list"
          : editor.isActive("orderedList")
            ? "ordered-list"
            : editor.isActive("codeBlock")
              ? "code-block"
              : "paragraph";

  const applyFormat = (format: RichTextFormat) => {
    switch (format) {
      case "paragraph":
        editor.chain().focus().setParagraph().run();
        break;
      case "heading-1":
        editor.chain().focus().toggleHeading({ level: 1 }).run();
        break;
      case "heading-2":
        editor.chain().focus().toggleHeading({ level: 2 }).run();
        break;
      case "heading-3":
        editor.chain().focus().toggleHeading({ level: 3 }).run();
        break;
      case "bullet-list":
        editor.chain().focus().toggleBulletList().run();
        break;
      case "ordered-list":
        editor.chain().focus().toggleOrderedList().run();
        break;
      case "code-block":
        editor.chain().focus().toggleCodeBlock().run();
        break;
    }
  };

  const insertImages = (files: FileList | null) => {
    const imageFiles = [...(files ?? [])].filter((file) => file.type.startsWith("image/"));
    uploadImages({ view: editor.view, files: imageFiles, imageSettings: imageUploadSettings });
  };

  return (
    <div className="grid gap-3 rounded border border-border bg-background p-3">
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={`${imageInputId}-format`}>Text format</Label>
        </FieldsetTitle>
        <Select
          id={`${imageInputId}-format`}
          value={activeFormat}
          onChange={(evt) => {
            const format = parseRichTextFormat(evt.target.value);
            if (format) applyFormat(format);
          }}
        >
          {RICH_TEXT_FORMAT_OPTIONS.map((option) => (
            <option key={option.id} value={option.id}>
              {option.label}
            </option>
          ))}
        </Select>
      </Fieldset>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" outline={editor.isActive("bold")} onClick={() => editor.chain().focus().toggleBold().run()}>
          <Bold className="size-4" />
          Bold
        </Button>
        <Button
          size="sm"
          outline={editor.isActive("italic")}
          onClick={() => editor.chain().focus().toggleItalic().run()}
        >
          <Italic className="size-4" />
          Italic
        </Button>
        <Button
          size="sm"
          outline={editor.isActive("underline")}
          onClick={() => editor.chain().focus().toggleUnderline().run()}
        >
          <UnderlineIcon className="size-4" />
          Underline
        </Button>
        <Button
          size="sm"
          outline={editor.isActive("strike")}
          onClick={() => editor.chain().focus().toggleStrike().run()}
        >
          <Strikethrough className="size-4" />
          Strikethrough
        </Button>
        <Button
          size="sm"
          outline={editor.isActive("blockquote")}
          onClick={() => editor.chain().focus().toggleBlockquote().run()}
        >
          <QuoteLeftAlt className="size-4" />
          Quote
        </Button>
        <Button size="sm" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
          <Minus className="size-4" />
          Divider
        </Button>
        <Button size="sm" disabled={undoDepth(editor.state) === 0} onClick={() => editor.chain().focus().undo().run()}>
          <Undo className="size-4" />
          Undo
        </Button>
        <Button size="sm" disabled={redoDepth(editor.state) === 0} onClick={() => editor.chain().focus().redo().run()}>
          <Redo className="size-4" />
          Redo
        </Button>
      </div>
      <Fieldset>
        <FieldsetTitle>
          <Label htmlFor={imageInputId}>Images</Label>
        </FieldsetTitle>
        <Input
          id={imageInputId}
          type="file"
          accept="image/*"
          multiple
          onChange={(evt) => {
            insertImages(evt.target.files);
            evt.currentTarget.value = "";
          }}
        />
      </Fieldset>
    </div>
  );
};

const SubscribeSectionFields = ({
  section,
  update,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfileSubscribeSection" }>;
  update: (section: Section) => void;
  commit: (section: Section) => void;
}) => (
  <Fieldset>
    <FieldsetTitle>
      <Label htmlFor={`${section.id}-button-label`}>Button label</Label>
    </FieldsetTitle>
    <Input
      id={`${section.id}-button-label`}
      value={section.button_label}
      onChange={(evt) => update({ ...section, button_label: evt.target.value })}
      onBlur={(evt) => commit({ ...section, button_label: evt.target.value })}
    />
  </Fieldset>
);

const FeaturedProductSectionFields = ({
  section,
  state,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfileFeaturedProductSection" }>;
  state: ProfileEditorProps;
  commit: (section: Section) => void;
}) => (
  <Fieldset>
    <FieldsetTitle>
      <Label htmlFor={`${section.id}-featured-product`}>Featured product</Label>
    </FieldsetTitle>
    <Select
      id={`${section.id}-featured-product`}
      value={section.featured_product_id ?? ""}
      onChange={(evt) => commit({ ...section, featured_product_id: evt.target.value || undefined })}
    >
      <option value="">Choose a product</option>
      {state.products.map((product) => (
        <option key={product.id} value={product.id}>
          {product.name}
        </option>
      ))}
    </Select>
  </Fieldset>
);

const WishlistsSectionFields = ({
  section,
  state,
  commit,
}: {
  section: Extract<Section, { type: "SellerProfileWishlistsSection" }>;
  state: ProfileEditorProps;
  commit: (section: Section) => void;
}) => {
  const orderedWishlists = sortBy(state.wishlist_options, (wishlist) => {
    const index = section.shown_wishlists.indexOf(wishlist.id);
    return index < 0 ? Infinity : index;
  });
  const selectedWishlists = orderedWishlists.filter((wishlist) => section.shown_wishlists.includes(wishlist.id));
  const toggleWishlist = (id: string) =>
    commit({
      ...section,
      shown_wishlists: section.shown_wishlists.includes(id)
        ? section.shown_wishlists.filter((wishlistId) => wishlistId !== id)
        : [...section.shown_wishlists, id],
    });
  const moveWishlist = (id: string, direction: -1 | 1) => {
    const index = section.shown_wishlists.indexOf(id);
    commit({ ...section, shown_wishlists: moveItem(section.shown_wishlists, index, direction) });
  };

  return (
    <Fieldset>
      <FieldsetTitle>Wishlists</FieldsetTitle>
      {orderedWishlists.length ? (
        <Rows role="list" aria-label="Wishlists">
          {orderedWishlists.map((wishlist) => {
            const selectedIndex = selectedWishlists.findIndex((selected) => selected.id === wishlist.id);
            return (
              <OptionCheckboxRow
                key={wishlist.id}
                name={wishlist.name}
                checked={section.shown_wishlists.includes(wishlist.id)}
                canMove
                isFirst={selectedIndex === 0}
                isLast={selectedIndex === selectedWishlists.length - 1}
                onToggle={() => toggleWishlist(wishlist.id)}
                onMove={(direction) => moveWishlist(wishlist.id, direction)}
              />
            );
          })}
        </Rows>
      ) : (
        <p>No wishlists available.</p>
      )}
    </Fieldset>
  );
};

export const ProfileSectionsForm = ({ onChange, disabled = false, ...props }: ProfileSectionsFormProps) => {
  const [sections, setSections] = React.useState(props.sections);
  const { tabs, setTabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const [newSectionType, setNewSectionType] = React.useState<Section["type"]>("SellerProfileProductsSection");
  const savedTabs = React.useRef(tabs);

  React.useEffect(() => {
    setSections((currentSections) => (isEqual(currentSections, props.sections) ? currentSections : props.sections));
  }, [props.sections]);

  const selectedTabIndex = Math.max(
    tabs.findIndex((tab) => tab.id === selectedTab?.id),
    0,
  );
  const visibleSectionIds = selectedTab?.sections ?? [];
  const visibleSections = visibleSectionIds.flatMap((id) => sections.find((section) => section.id === id) ?? []);

  React.useEffect(
    () => onChange?.({ sections, tabs: tabsWithoutIds(tabs), selectedTabIndex }),
    [onChange, sections, selectedTabIndex, tabs],
  );

  const saveTabs = async (nextTabs = tabs, options: { showSuccess?: boolean } = {}) => {
    if (disabled) return false;

    setTabs(nextTabs);
    if (isEqual(tabsWithoutIds(nextTabs), tabsWithoutIds(savedTabs.current))) return true;
    try {
      await updateProfileSettings({ tabs: tabsWithoutIds(nextTabs) });
      if (options.showSuccess ?? true) showAlert("Changes saved!", "success");
      savedTabs.current = nextTabs;
      return true;
    } catch (e) {
      assertResponseError(e);
      const rollbackTabs = savedTabs.current;
      setTabs(rollbackTabs);
      const rollbackSelectedTab = rollbackTabs.find((tab) => tab.id === selectedTab?.id) ?? rollbackTabs[0];
      if (rollbackSelectedTab) setSelectedTab(rollbackSelectedTab);
      showAlert(e.message, "error");
      return false;
    }
  };

  const updateSection = (updated: Section) => {
    setSections((currentSections) => currentSections.map((section) => (section.id === updated.id ? updated : section)));
  };

  const addPage = async () => {
    if (disabled) return;

    const tab = { id: GuidGenerator.generate(), name: "New page", sections: [] };
    const nextTabs = [...tabs, tab];
    setSelectedTab(tab);
    await saveTabs(nextTabs);
  };

  const updatePageName = (name: string) => {
    if (disabled || !selectedTab) return;
    setTabs(tabs.map((tab) => (tab.id === selectedTab.id ? { ...tab, name } : tab)));
  };

  const commitPageName = async (name: string) => {
    if (disabled || !selectedTab) return;
    await saveTabs(tabs.map((tab) => (tab.id === selectedTab.id ? { ...tab, name } : tab)));
  };

  const removePage = async () => {
    if (disabled || !selectedTab) return;
    const removedSectionIds = new Set(selectedTab.sections);
    try {
      const nextTabs = tabs.filter((tab) => tab.id !== selectedTab.id);
      if (nextTabs[0]) setSelectedTab(nextTabs[0]);
      const tabsSaved = await saveTabs(nextTabs, { showSuccess: false });
      if (!tabsSaved) return;

      await Promise.all(
        sections
          .filter((section) => removedSectionIds.has(section.id))
          .map(async (section) => {
            const response = await request({
              method: "DELETE",
              url: Routes.profile_section_path(section.id),
              accept: "json",
            });
            await assertResponseOk(response);
          }),
      );
      setSections((currentSections) => currentSections.filter((section) => !removedSectionIds.has(section.id)));
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const movePage = async (direction: -1 | 1) => {
    if (disabled) return;

    const index = selectedTabIndex;
    const nextTabs = moveItem(tabs, index, direction);
    const nextSelectedTab = nextTabs[index + direction];
    if (nextSelectedTab) setSelectedTab(nextSelectedTab);
    await saveTabs(nextTabs);
  };

  const createSectionRecord = async (section: Omit<Section, "id">) => {
    const response = await request({
      method: "POST",
      url: Routes.profile_sections_path(),
      data: section,
      accept: "json",
    });
    const json: unknown = await response.json();
    if (!response.ok) throw new ResponseError(typia.assert<{ error: string }>(json).error);
    return typia.assert<{ id: string }>(json).id;
  };

  const createSection = async (type: Section["type"]): Promise<Section> => {
    const commonProps = { header: "New section", hide_header: false, product_id: props.product_id };

    switch (type) {
      case "SellerProfileProductsSection": {
        const section: Omit<Extract<Section, { type: "SellerProfileProductsSection" }>, "id"> = {
          ...commonProps,
          type,
          shown_products: [],
          default_product_sort: "page_layout",
          show_filters: false,
          add_new_products: true,
          search_results: { products: [], total: 0, filetypes_data: [], tags_data: [] },
        };
        return { ...section, id: await createSectionRecord(section) };
      }
      case "SellerProfilePostsSection": {
        const section: Omit<Extract<Section, { type: "SellerProfilePostsSection" }>, "id"> = {
          ...commonProps,
          type,
          shown_posts: props.posts.map((post) => post.id),
        };
        return { ...section, id: await createSectionRecord(section) };
      }
      case "SellerProfileRichTextSection": {
        const section: Omit<Extract<Section, { type: "SellerProfileRichTextSection" }>, "id"> = {
          ...commonProps,
          type,
          text: {},
        };
        return { ...section, id: await createSectionRecord(section) };
      }
      case "SellerProfileSubscribeSection": {
        const section: Omit<Extract<Section, { type: "SellerProfileSubscribeSection" }>, "id"> = {
          ...commonProps,
          type,
          header: `Subscribe to receive email updates from ${props.creator_profile.name}.`,
          button_label: "Subscribe",
        };
        return { ...section, id: await createSectionRecord(section) };
      }
      case "SellerProfileFeaturedProductSection": {
        const section: Omit<Extract<Section, { type: "SellerProfileFeaturedProductSection" }>, "id"> = {
          ...commonProps,
          type,
        };
        return { ...section, id: await createSectionRecord(section) };
      }
      case "SellerProfileWishlistsSection": {
        const section: Omit<Extract<Section, { type: "SellerProfileWishlistsSection" }>, "id"> = {
          ...commonProps,
          type,
          shown_wishlists: [],
        };
        return { ...section, id: await createSectionRecord(section) };
      }
    }
  };

  const addSection = async () => {
    if (disabled) return;

    try {
      const tab = selectedTab ?? { id: GuidGenerator.generate(), name: "New page", sections: [] };
      const baseTabs = selectedTab ? tabs : [tab];
      const section = await createSection(newSectionType);
      const nextTabs = baseTabs.map((existing) =>
        existing.id === tab.id ? { ...existing, sections: [...existing.sections, section.id] } : existing,
      );
      const nextSelectedTab = nextTabs.find((existing) => existing.id === tab.id);
      setSections((currentSections) => [...currentSections, section]);
      if (nextSelectedTab) setSelectedTab(nextSelectedTab);
      await saveTabs(nextTabs);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const removeSection = async (sectionId: string) => {
    if (disabled) return;

    try {
      const tabsSaved = await saveTabs(
        tabs.map((tab) => ({ ...tab, sections: tab.sections.filter((id) => id !== sectionId) })),
        { showSuccess: false },
      );
      if (!tabsSaved) return;

      const response = await request({ method: "DELETE", url: Routes.profile_section_path(sectionId), accept: "json" });
      await assertResponseOk(response);
      setSections((currentSections) => currentSections.filter((section) => section.id !== sectionId));
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const moveSection = async (sectionId: string, direction: -1 | 1) => {
    if (disabled || !selectedTab) return;
    const sectionIndex = selectedTab.sections.indexOf(sectionId);
    const updatedTab = { ...selectedTab, sections: moveItem(selectedTab.sections, sectionIndex, direction) };
    await saveTabs(tabs.map((tab) => (tab.id === selectedTab.id ? updatedTab : tab)));
  };

  return (
    <div className="grid gap-8 px-4 pb-8 md:px-8">
      <Fieldset disabled={disabled}>
        <FieldsetTitle>Pages</FieldsetTitle>
        <div className="grid gap-4">
          {tabs.length ? (
            <>
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor="profile-page">Current page</Label>
                </FieldsetTitle>
                <Select
                  id="profile-page"
                  value={selectedTab?.id ?? ""}
                  onChange={(evt) => {
                    const tab = tabs.find(({ id }) => id === evt.target.value);
                    if (tab) setSelectedTab(tab);
                  }}
                >
                  {tabs.map((tab, index) => (
                    <option key={tab.id} value={tab.id}>
                      {tab.name || `Page ${index + 1}`}
                    </option>
                  ))}
                </Select>
              </Fieldset>
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor="profile-page-name">Page name</Label>
                </FieldsetTitle>
                <Input
                  id="profile-page-name"
                  value={selectedTab?.name ?? ""}
                  onChange={(evt) => updatePageName(evt.target.value)}
                  onBlur={(evt) => void commitPageName(evt.target.value)}
                />
              </Fieldset>
              <div className="flex flex-wrap gap-2">
                <Button size="sm" onClick={() => void movePage(-1)} disabled={selectedTabIndex === 0}>
                  <ArrowUp className="size-4" />
                  Move page up
                </Button>
                <Button size="sm" onClick={() => void movePage(1)} disabled={selectedTabIndex === tabs.length - 1}>
                  <ArrowDown className="size-4" />
                  Move page down
                </Button>
                <Button size="sm" color="danger" onClick={() => void removePage()}>
                  <Trash className="size-4" />
                  Remove page
                </Button>
              </div>
            </>
          ) : (
            <p>No pages yet.</p>
          )}
          <Button onClick={() => void addPage()}>
            <Plus className="size-5" />
            Add page
          </Button>
        </div>
      </Fieldset>

      <Fieldset disabled={disabled}>
        <FieldsetTitle>Sections</FieldsetTitle>
        <div className="grid gap-4">
          <div className="grid gap-3 sm:grid-cols-[1fr_auto]">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="new-profile-section-type">Section type</Label>
              </FieldsetTitle>
              <Select
                id="new-profile-section-type"
                value={newSectionType}
                onChange={(evt) => {
                  const sectionType = parseSectionType(evt.target.value);
                  if (sectionType) setNewSectionType(sectionType);
                }}
              >
                {SECTION_TYPE_OPTIONS.map((option) => (
                  <option key={option.id} value={option.id}>
                    {option.label}
                  </option>
                ))}
              </Select>
            </Fieldset>
            <Button className="self-end" onClick={() => void addSection()}>
              <Plus className="size-5" />
              Add section
            </Button>
          </div>
          {visibleSections.length ? (
            visibleSections.map((section, index) => (
              <SectionForm
                key={section.id}
                section={section}
                index={index}
                count={visibleSections.length}
                state={{ ...props, sections }}
                updateSection={updateSection}
                moveSection={(sectionId, direction) => void moveSection(sectionId, direction)}
                removeSection={(sectionId) => void removeSection(sectionId)}
              />
            ))
          ) : (
            <p>This page has no sections yet.</p>
          )}
        </div>
      </Fieldset>
    </div>
  );
};
