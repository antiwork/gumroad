import {
  Bell,
  Box,
  ChevronDown,
  ChevronUp,
  Copy,
  Envelope,
  File,
  FileDetail,
  Grid,
  Plus,
  Trash,
} from "@boxicons/react";
import { EditorContent } from "@tiptap/react";
import { debounce, isEqual, sortBy } from "lodash-es";
import * as React from "react";
import typia from "typia";

import { PROFILE_SORT_KEYS, type ProfileSortKey } from "$app/parsers/product";
import GuidGenerator from "$app/utils/guid_generator";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { SORT_BY_LABELS } from "$app/components/Product/CardGrid";
import { TabWithId, useTabs } from "$app/components/Profile";
import type { ProfileEditorProps, ProfileEditorState } from "$app/components/Profile/EditPage";
import { Section, useSectionImageUploadSettings } from "$app/components/Profile/EditSections";
import { ImageUploadSettingsContext, RichTextEditorToolbar, useRichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, RowDetails, Rows } from "$app/components/ui/Rows";
import { Select } from "$app/components/ui/Select";
import { Switch } from "$app/components/ui/Switch";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

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

const SECTION_TYPE_ICONS: Record<Section["type"], React.ReactNode> = {
  SellerProfileProductsSection: <Grid className="size-5" />,
  SellerProfilePostsSection: <Envelope pack="filled" className="size-5" />,
  SellerProfileFeaturedProductSection: <Box className="size-5" />,
  SellerProfileRichTextSection: <FileDetail className="size-5" />,
  SellerProfileSubscribeSection: <Bell pack="filled" className="size-5" />,
  SellerProfileWishlistsSection: <FileDetail pack="filled" className="size-5" />,
};

const SECTION_TYPES: Section["type"][] = [
  "SellerProfileProductsSection",
  "SellerProfilePostsSection",
  "SellerProfileFeaturedProductSection",
  "SellerProfileRichTextSection",
  "SellerProfileSubscribeSection",
  "SellerProfileWishlistsSection",
];

const tabsWithoutIds = (tabs: ReturnType<typeof useTabs>["tabs"]) => tabs.map(({ id: _id, ...tab }) => tab);

const parseProfileSortKey = (value: string): ProfileSortKey | null =>
  PROFILE_SORT_KEYS.find((key) => key === value) ?? null;

const optionOrder = (ids: string[], shownIds: string[]) =>
  sortBy(ids, (id) => {
    const index = shownIds.indexOf(id);
    return index < 0 ? Infinity : index;
  });

const SortablePageRows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <Rows ref={ref} role="list" aria-label="Pages">
    {children}
  </Rows>
));
SortablePageRows.displayName = "SortablePageRows";

const SortableSectionRows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <Rows ref={ref} role="list" aria-label="Sections">
    {children}
  </Rows>
));
SortableSectionRows.displayName = "SortableSectionRows";

const SortableProductRows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <Rows ref={ref} role="list" aria-label="Products">
    {children}
  </Rows>
));
SortableProductRows.displayName = "SortableProductRows";

const SortableWishlistRows = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <Rows ref={ref} role="list" aria-label="Wishlists">
    {children}
  </Rows>
));
SortableWishlistRows.displayName = "SortableWishlistRows";

const DrawerToggle = ({ isOpen, onToggle, label }: { isOpen: boolean; onToggle: () => void; label: string }) => (
  <WithTooltip tip={isOpen ? "Close drawer" : "Open drawer"}>
    <Button size="icon" onClick={onToggle} aria-label={`${isOpen ? "Collapse" : "Expand"} ${label}`}>
      {isOpen ? <ChevronUp className="size-5" /> : <ChevronDown className="size-5" />}
    </Button>
  </WithTooltip>
);

const OptionRow = ({
  name,
  checked,
  draggable = false,
  onToggle,
}: {
  name: string;
  checked: boolean;
  draggable?: boolean;
  onToggle: () => void;
}) => (
  <Row asChild>
    <Label role="listitem">
      <RowContent>
        {draggable ? <ReorderingHandle /> : null}
        <span className="truncate">{name}</span>
      </RowContent>
      <RowActions>
        <Checkbox checked={checked} onChange={onToggle} />
      </RowActions>
    </Label>
  </Row>
);

const PageRow = ({
  tab,
  shouldFocusName,
  updateName,
  onDelete,
}: {
  tab: TabWithId;
  shouldFocusName: boolean;
  updateName: (name: string) => void;
  onDelete: () => void;
}) => {
  const nameInputRef = React.useRef<HTMLInputElement>(null);
  React.useEffect(() => {
    if (!shouldFocusName) return;
    const frame = requestAnimationFrame(() => nameInputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [shouldFocusName]);

  return (
    <Row role="listitem">
      <RowContent className="grow">
        <ReorderingHandle />
        <File className="size-5 shrink-0" />
        <Input
          ref={nameInputRef}
          type="text"
          aria-label="Page name"
          value={tab.name}
          onChange={(evt) => updateName(evt.target.value)}
        />
      </RowContent>
      <RowActions>
        <WithTooltip tip="Remove">
          <Button size="icon" onClick={onDelete} aria-label="Remove page">
            <Trash className="size-5" />
          </Button>
        </WithTooltip>
      </RowActions>
    </Row>
  );
};

const SectionRow = ({
  section,
  state,
  shouldFocusHeader,
  updateSection,
  onDelete,
}: {
  section: Section;
  state: ProfileEditorProps;
  shouldFocusHeader: boolean;
  updateSection: (section: Section) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const [isOpen, setIsOpen] = React.useState(true);
  const headerInputRef = React.useRef<HTMLInputElement>(null);
  React.useEffect(() => {
    if (!shouldFocusHeader) return;
    const frame = requestAnimationFrame(() => headerInputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [shouldFocusHeader]);
  const sectionTitle = section.header || SECTION_TYPE_LABELS[section.type];
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
    <Row role="listitem" aria-label={`${sectionTitle} section settings`}>
      <RowContent>
        <ReorderingHandle />
        {SECTION_TYPE_ICONS[section.type]}
        <h3>{sectionTitle}</h3>
      </RowContent>
      <RowActions>
        <WithTooltip tip="Copy link">
          <Button size="icon" onClick={copyLink} aria-label="Copy link">
            <Copy className="size-5" />
          </Button>
        </WithTooltip>
        <DrawerToggle
          isOpen={isOpen}
          onToggle={() => setIsOpen((prevIsOpen) => !prevIsOpen)}
          label={`${sectionTitle} section`}
        />
        <WithTooltip tip="Remove">
          <Button size="icon" onClick={onDelete} aria-label="Remove section">
            <Trash className="size-5" />
          </Button>
        </WithTooltip>
      </RowActions>
      {isOpen ? (
        <RowDetails asChild>
          <Drawer className="grid gap-6">
            <Fieldset>
              <Label htmlFor={`${uid}-header`}>Section name</Label>
              <Input
                ref={headerInputRef}
                id={`${uid}-header`}
                type="text"
                value={section.header}
                onChange={(evt) => update({ ...section, header: evt.target.value })}
              />
            </Fieldset>
            <Switch
              checked={!section.hide_header}
              onChange={() => update({ ...section, hide_header: !section.hide_header })}
              label="Show section name"
            />
            {section.type === "SellerProfileProductsSection" ? (
              <ProductsSectionFields section={section} state={state} update={update} />
            ) : section.type === "SellerProfilePostsSection" ? (
              <PostsSectionFields section={section} state={state} update={update} />
            ) : section.type === "SellerProfileRichTextSection" ? (
              <RichTextSectionFields section={section} update={update} />
            ) : section.type === "SellerProfileSubscribeSection" ? (
              <SubscribeSectionFields section={section} update={update} />
            ) : section.type === "SellerProfileFeaturedProductSection" ? (
              <FeaturedProductSectionFields section={section} state={state} update={update} />
            ) : (
              <WishlistsSectionFields section={section} state={state} update={update} />
            )}
          </Drawer>
        </RowDetails>
      ) : null}
    </Row>
  );
};

const ProductsSectionFields = ({
  section,
  state,
  update,
}: {
  section: Extract<Section, { type: "SellerProfileProductsSection" }>;
  state: ProfileEditorProps;
  update: (section: Section) => void;
}) => {
  const uid = React.useId();
  const [orderedProductIds, setOrderedProductIds] = React.useState(() =>
    optionOrder(
      state.products.map(({ id }) => id),
      section.shown_products,
    ),
  );
  const orderedProducts = orderedProductIds.flatMap((id) => state.products.find((product) => product.id === id) ?? []);
  const canReorder = section.default_product_sort === "page_layout";

  const toggleProduct = (id: string) =>
    update({
      ...section,
      shown_products: section.shown_products.includes(id)
        ? section.shown_products.filter((productId) => productId !== id)
        : orderedProductIds.filter((productId) => productId === id || section.shown_products.includes(productId)),
    });

  const reorderProducts = (newOrder: string[]) => {
    setOrderedProductIds(newOrder);
    update({ ...section, shown_products: sortBy(section.shown_products, (id) => newOrder.indexOf(id)) });
  };

  return (
    <>
      <Fieldset>
        <Label htmlFor={`${uid}-default-sort`}>Default sort order</Label>
        <Select
          id={`${uid}-default-sort`}
          value={section.default_product_sort}
          onChange={(evt) => {
            const default_product_sort = parseProfileSortKey(evt.target.value);
            if (default_product_sort) update({ ...section, default_product_sort });
          }}
        >
          {PROFILE_SORT_KEYS.map((key) => (
            <option key={key} value={key}>
              {SORT_BY_LABELS[key]}
            </option>
          ))}
        </Select>
      </Fieldset>
      <Switch
        checked={section.show_filters}
        onChange={() => update({ ...section, show_filters: !section.show_filters })}
        label="Show product filters"
      />
      <Switch
        checked={section.add_new_products}
        onChange={() => update({ ...section, add_new_products: !section.add_new_products })}
        label="Add new products by default"
      />
      <Fieldset>
        <FieldsetTitle>Products</FieldsetTitle>
        {orderedProducts.length ? (
          <SortableList currentOrder={orderedProductIds} onReorder={reorderProducts} tag={SortableProductRows}>
            {orderedProducts.map((product) => (
              <OptionRow
                key={product.id}
                name={product.name}
                checked={section.shown_products.includes(product.id)}
                draggable={canReorder}
                onToggle={() => toggleProduct(product.id)}
              />
            ))}
          </SortableList>
        ) : (
          <p>No products available.</p>
        )}
      </Fieldset>
    </>
  );
};

const PostsSectionFields = ({
  section,
  state,
  update,
}: {
  section: Extract<Section, { type: "SellerProfilePostsSection" }>;
  state: ProfileEditorProps;
  update: (section: Section) => void;
}) => {
  const togglePost = (id: string) =>
    update({
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
            <OptionRow
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
  update,
}: {
  section: Extract<Section, { type: "SellerProfileRichTextSection" }>;
  update: (section: Section) => void;
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
    const syncText = () => {
      if (isUploadingRef.current) return;
      update({ ...sectionRef.current, text: editor.getJSON() });
    };
    const debouncedSyncText = debounce(syncText, 2000);
    editor.on("blur", syncText);
    editor.on("update", debouncedSyncText);
    return () => {
      editor.off("blur", syncText);
      editor.off("update", debouncedSyncText);
    };
  }, [editor]);

  return (
    <Fieldset>
      <FieldsetTitle>Text</FieldsetTitle>
      <ImageUploadSettingsContext.Provider value={imageUploadSettings}>
        <div className="grid grid-rows-[max-content_1fr] rounded">
          {editor ? (
            <RichTextEditorToolbar
              editor={editor}
              className="rounded-t rounded-b-none border border-b-0 border-border"
            />
          ) : null}
          <EditorContent editor={editor} className="rich-text rounded-b border border-border p-4" />
        </div>
      </ImageUploadSettingsContext.Provider>
    </Fieldset>
  );
};

const SubscribeSectionFields = ({
  section,
  update,
}: {
  section: Extract<Section, { type: "SellerProfileSubscribeSection" }>;
  update: (section: Section) => void;
}) => (
  <Fieldset>
    <Label htmlFor={`${section.id}-button-label`}>Button label</Label>
    <Input
      id={`${section.id}-button-label`}
      type="text"
      value={section.button_label}
      onChange={(evt) => update({ ...section, button_label: evt.target.value })}
    />
  </Fieldset>
);

const FeaturedProductSectionFields = ({
  section,
  state,
  update,
}: {
  section: Extract<Section, { type: "SellerProfileFeaturedProductSection" }>;
  state: ProfileEditorProps;
  update: (section: Section) => void;
}) => (
  <Fieldset>
    <Label htmlFor={`${section.id}-featured-product`}>Featured product</Label>
    <Select
      id={`${section.id}-featured-product`}
      value={section.featured_product_id ?? ""}
      onChange={(evt) => update({ ...section, featured_product_id: evt.target.value || undefined })}
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
  update,
}: {
  section: Extract<Section, { type: "SellerProfileWishlistsSection" }>;
  state: ProfileEditorProps;
  update: (section: Section) => void;
}) => {
  const [orderedWishlistIds, setOrderedWishlistIds] = React.useState(() =>
    optionOrder(
      state.wishlist_options.map(({ id }) => id),
      section.shown_wishlists,
    ),
  );
  const orderedWishlists = orderedWishlistIds.flatMap(
    (id) => state.wishlist_options.find((wishlist) => wishlist.id === id) ?? [],
  );

  const toggleWishlist = (id: string) =>
    update({
      ...section,
      shown_wishlists: section.shown_wishlists.includes(id)
        ? section.shown_wishlists.filter((wishlistId) => wishlistId !== id)
        : orderedWishlistIds.filter((wishlistId) => wishlistId === id || section.shown_wishlists.includes(wishlistId)),
    });

  const reorderWishlists = (newOrder: string[]) => {
    setOrderedWishlistIds(newOrder);
    update({ ...section, shown_wishlists: sortBy(section.shown_wishlists, (id) => newOrder.indexOf(id)) });
  };

  return (
    <Fieldset>
      <FieldsetTitle>Wishlists</FieldsetTitle>
      {orderedWishlists.length ? (
        <SortableList currentOrder={orderedWishlistIds} onReorder={reorderWishlists} tag={SortableWishlistRows}>
          {orderedWishlists.map((wishlist) => (
            <OptionRow
              key={wishlist.id}
              name={wishlist.name}
              checked={section.shown_wishlists.includes(wishlist.id)}
              draggable
              onToggle={() => toggleWishlist(wishlist.id)}
            />
          ))}
        </SortableList>
      ) : (
        <p>No wishlists available.</p>
      )}
    </Fieldset>
  );
};

export const ProfileSectionsForm = ({ onChange, disabled = false, ...props }: ProfileSectionsFormProps) => {
  const [sections, setSections] = React.useState(props.sections);
  const { tabs, setTabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const [deletionModalPageId, setDeletionModalPageId] = React.useState<string | null>(null);
  const [deletionModalSectionId, setDeletionModalSectionId] = React.useState<string | null>(null);
  const [addSectionMenuOpen, setAddSectionMenuOpen] = React.useState(false);
  const [lastAddedPageId, setLastAddedPageId] = React.useState<string | null>(null);
  const [lastAddedSectionId, setLastAddedSectionId] = React.useState<string | null>(null);

  React.useEffect(() => {
    setSections((currentSections) => (isEqual(currentSections, props.sections) ? currentSections : props.sections));
  }, [props.sections]);

  const selectedTabIndex = Math.max(
    tabs.findIndex((tab) => tab.id === selectedTab?.id),
    0,
  );
  const visibleSectionIds = selectedTab?.sections ?? [];
  const visibleSections = visibleSectionIds.flatMap((id) => sections.find((section) => section.id === id) ?? []);

  const deletionModalPage = tabs.find(({ id }) => id === deletionModalPageId);
  const deletionModalSection = sections.find(({ id }) => id === deletionModalSectionId);
  const deletionModalSectionTitle = deletionModalSection
    ? deletionModalSection.header || SECTION_TYPE_LABELS[deletionModalSection.type]
    : "";

  React.useEffect(
    () => onChange?.({ sections, tabs: tabsWithoutIds(tabs), selectedTabIndex }),
    [onChange, sections, selectedTabIndex, tabs],
  );

  const updateSection = (updated: Section) => {
    setSections((currentSections) => currentSections.map((section) => (section.id === updated.id ? updated : section)));
  };

  const addPage = () => {
    if (disabled) return;

    const tab = { id: GuidGenerator.generate(), name: "New page", sections: [] };
    setLastAddedPageId(tab.id);
    setSelectedTab(tab);
    setTabs([...tabs, tab]);
  };

  const updatePageName = (tabId: string, name: string) => {
    if (disabled) return;
    setTabs(tabs.map((tab) => (tab.id === tabId ? { ...tab, name } : tab)));
  };

  const removePage = (tabId: string) => {
    if (disabled) return;
    const removedTab = tabs.find(({ id }) => id === tabId);
    if (!removedTab) return;
    const removedSectionIds = new Set(removedTab.sections);
    const nextTabs = tabs.filter(({ id }) => id !== tabId);
    if (selectedTab?.id === tabId && nextTabs[0]) setSelectedTab(nextTabs[0]);
    setTabs(nextTabs);
    setSections((currentSections) => currentSections.filter((section) => !removedSectionIds.has(section.id)));
  };

  const reorderPages = (newOrder: string[]) => {
    if (disabled) return;
    setTabs(newOrder.flatMap((id) => tabs.find((tab) => tab.id === id) ?? []));
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
    const commonProps = { header: "", hide_header: false, product_id: props.product_id };

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

  const addSection = async (type: Section["type"]) => {
    if (disabled) return;

    try {
      const tab = selectedTab ?? { id: GuidGenerator.generate(), name: "New page", sections: [] };
      const baseTabs = selectedTab ? tabs : [tab];
      const section = await createSection(type);
      const nextTabs = baseTabs.map((existing) =>
        existing.id === tab.id ? { ...existing, sections: [...existing.sections, section.id] } : existing,
      );
      const nextSelectedTab = nextTabs.find((existing) => existing.id === tab.id);
      setLastAddedSectionId(section.id);
      setSections((currentSections) => [...currentSections, section]);
      if (nextSelectedTab) setSelectedTab(nextSelectedTab);
      setTabs(nextTabs);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const removeSection = (sectionId: string) => {
    if (disabled) return;

    setTabs(tabs.map((tab) => ({ ...tab, sections: tab.sections.filter((id) => id !== sectionId) })));
    setSections((currentSections) => currentSections.filter((section) => section.id !== sectionId));
  };

  const reorderSections = (newOrder: string[]) => {
    if (disabled || !selectedTab) return;
    setTabs(tabs.map((tab) => (tab.id === selectedTab.id ? { ...tab, sections: newOrder } : tab)));
  };

  const addPageButton = (
    <Button color="primary" onClick={addPage}>
      <Plus className="size-5" />
      Add page
    </Button>
  );

  const addSectionButton = (
    <Popover open={addSectionMenuOpen} onOpenChange={setAddSectionMenuOpen}>
      <PopoverTrigger asChild>
        <Button color="primary">
          <Plus className="size-5" />
          Add section
        </Button>
      </PopoverTrigger>
      <PopoverContent className="border-0 p-0 shadow-none">
        <Menu onClick={() => setAddSectionMenuOpen(false)}>
          {SECTION_TYPES.map((type) => (
            <MenuItem key={type} onClick={() => void addSection(type)}>
              {SECTION_TYPE_ICONS[type]}
              {SECTION_TYPE_LABELS[type]}
            </MenuItem>
          ))}
        </Menu>
      </PopoverContent>
    </Popover>
  );

  return (
    <>
      {deletionModalPage ? (
        <Modal
          open
          onClose={() => setDeletionModalPageId(null)}
          title={`Remove ${deletionModalPage.name || "Untitled"}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalPageId(null)}>No, cancel</Button>
              <Button
                color="accent"
                onClick={() => {
                  setDeletionModalPageId(null);
                  removePage(deletionModalPage.id);
                }}
              >
                Yes, remove
              </Button>
            </>
          }
        >
          If you remove this page, all of its sections will be deleted as well. This action cannot be undone.
        </Modal>
      ) : null}
      {deletionModalSection ? (
        <Modal
          open
          onClose={() => setDeletionModalSectionId(null)}
          title={`Remove ${deletionModalSectionTitle}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalSectionId(null)}>No, cancel</Button>
              <Button
                color="accent"
                onClick={() => {
                  setDeletionModalSectionId(null);
                  removeSection(deletionModalSection.id);
                }}
              >
                Yes, remove
              </Button>
            </>
          }
        >
          This will permanently delete the section and its settings. Your products, posts, and wishlists themselves
          won't be affected.
        </Modal>
      ) : null}

      <section className="grid gap-8 border-t border-border p-4! md:p-8!">
        <h2>Pages</h2>
        <Fieldset disabled={disabled}>
          {tabs.length === 0 ? (
            <Placeholder>
              <h2>Build your profile</h2>
              Add pages to organize your products, posts, and more.
              {addPageButton}
            </Placeholder>
          ) : (
            <div className="grid gap-8">
              <SortableList currentOrder={tabs.map(({ id }) => id)} onReorder={reorderPages} tag={SortablePageRows}>
                {tabs.map((tab) => (
                  <PageRow
                    key={tab.id}
                    tab={tab}
                    shouldFocusName={tab.id === lastAddedPageId}
                    updateName={(name) => updatePageName(tab.id, name)}
                    onDelete={() => setDeletionModalPageId(tab.id)}
                  />
                ))}
              </SortableList>
              {addPageButton}
            </div>
          )}
        </Fieldset>
      </section>

      <section className="grid gap-8 border-t border-border p-4! md:p-8!">
        <h2>Sections</h2>
        <Fieldset disabled={disabled}>
          <div className="grid gap-8">
            {tabs.length > 1 ? (
              <Tabs aria-label="Pages">
                {tabs.map((tab, index) => (
                  <Tab key={tab.id} isSelected={tab.id === selectedTab?.id} onClick={() => setSelectedTab(tab)}>
                    {tab.name || `Page ${index + 1}`}
                  </Tab>
                ))}
              </Tabs>
            ) : null}
            {visibleSections.length === 0 ? (
              <Placeholder>
                <h2>Build your page</h2>
                Add sections to showcase your products, posts, and more.
                {addSectionButton}
              </Placeholder>
            ) : (
              <>
                <SortableList
                  currentOrder={visibleSections.map(({ id }) => id)}
                  onReorder={reorderSections}
                  tag={SortableSectionRows}
                >
                  {visibleSections.map((section) => (
                    <SectionRow
                      key={section.id}
                      section={section}
                      state={{ ...props, sections }}
                      shouldFocusHeader={section.id === lastAddedSectionId}
                      updateSection={updateSection}
                      onDelete={() => setDeletionModalSectionId(section.id)}
                    />
                  ))}
                </SortableList>
                {addSectionButton}
              </>
            )}
          </div>
        </Fieldset>
      </section>
    </>
  );
};
