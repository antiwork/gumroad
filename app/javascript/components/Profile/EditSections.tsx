import { DirectUpload } from "@rails/activestorage";
import { EditorContent } from "@tiptap/react";
import debounce from "lodash/debounce";
import isEqual from "lodash/isEqual";
import sortBy from "lodash/sortBy";
import * as React from "react";
import { ReactSortable as Sortable } from "react-sortablejs";
import { cast } from "ts-safe-cast";

import {
  FeaturedProductSection,
  getProduct,
  PostsSection,
  ProductsSection as SavedProductsSection,
  RichTextSection,
  Section as BaseSection,
  SubscribeSection,
  WishlistsSection,
} from "$app/data/profile_settings";
import { SearchResults } from "$app/data/search";
import { PROFILE_SORT_KEYS } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { Popover, Props as PopoverProps } from "$app/components/Popover";
import { Props as ProductProps } from "$app/components/Product";
import { CardGrid, SORT_BY_LABELS, useSearchReducer } from "$app/components/Product/CardGrid";
import { WishlistsSectionView } from "$app/components/Profile/EditSections/WishlistsSectionView";
import { RichTextEditorToolbar, useImageUploadSettings, useRichTextEditor } from "$app/components/RichTextEditor";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { useOnChange } from "$app/components/useOnChange";
import { useRefToLatest } from "$app/components/useRefToLatest";

import { FeaturedProductView, Post, PostsView, PageProps as BasePageProps, SubscribeView } from "./Sections";

type ProductsSection = SavedProductsSection & { search_results: SearchResults };
type EditProduct = { id: string; name: string };
export type Section =
  | ProductsSection
  | PostsSection
  | RichTextSection
  | SubscribeSection
  | FeaturedProductSection
  | WishlistsSection;

export type PageProps = Omit<BasePageProps, "sections"> & {
  sections: Section[];
  products: EditProduct[];
  posts: Post[];
  wishlist_options: { id: string; name: string }[];
  product_id?: string;
};

export type Action =
  | { type: "add-section"; index: number; section: Promise<Section> } // use a Promise so the wrapping component can keep track of where the new section should be displayed
  | { type: "update-section"; updated: Section }
  | { type: "move-section-up"; id: string }
  | { type: "move-section-down"; id: string }
  | { type: "remove-section"; id: string };
export const ReducerContext = React.createContext<readonly [PageProps, React.Dispatch<Action>] | null>(null);
export const useReducer = () => assertDefined(React.useContext(ReducerContext));

const useSaveSection = (initialSection: Section) => {
  const [savedSection, setSavedSection] = React.useState(initialSection);
  return async (section: Section) => {
    if (isEqual(savedSection, section)) return;
    try {
      const response = await request({
        method: "PATCH",
        url: Routes.profile_section_path(section.id),
        data: section,
        accept: "json",
      });
      if (!response.ok) throw new ResponseError(cast<{ error: string }>(await response.json()).error);
      showAlert("Changes saved!", "success");
      setSavedSection(section);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };
};

export const useSectionImageUploadSettings = () => {
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
  const imageUploadSettings = React.useMemo(
    () => ({
      isUploading: imagesUploading.size > 0,
      onUpload: (file: File) => {
        setImagesUploading((prev) => new Set(prev).add(file));
        return new Promise<string>((resolve, reject) => {
          const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
          upload.create((error, blob) => {
            setImagesUploading((prev) => {
              const updated = new Set(prev);
              updated.delete(file);
              return updated;
            });

            if (error) reject(error);
            else
              request({
                method: "GET",
                accept: "json",
                url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
              })
                .then((response) => response.json())
                .then((data) => resolve(cast<{ url: string }>(data).url))
                .catch((e: unknown) => {
                  assertResponseError(e);
                  reject(e);
                });
          });
        });
      },
      allowedExtensions: ALLOWED_EXTENSIONS,
    }),
    [imagesUploading.size],
  );

  React.useEffect(() => {
    if (imagesUploading.size === 0) return;

    const beforeUnload = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", beforeUnload);

    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [imagesUploading]);

  return imageUploadSettings;
};

const sectionButtonClasses = "w-[calc(1lh+--spacing(2))] py-1 text-center hover:bg-gray-300/50";

type SubmenuProps = { heading: string; children: React.ReactNode; text: React.ReactNode };
export const EditorSubmenu = ({ children }: SubmenuProps) => children;
export const EditorMenu = ({
  onClose,
  children,
  label,
}: {
  onClose: () => void;
  children: React.ReactNode;
  label: string;
}) => {
  const items = React.Children.toArray(children);
  const [menuState, setMenuState] = React.useState<number | "menu">("menu");
  const activeSubmenu = typeof menuState === "number" ? items[menuState] : null;
  const isSubmenu = (element: React.ReactNode): element is React.ReactElement<SubmenuProps> =>
    React.isValidElement(element) && element.type === EditorSubmenu;

  return (
    <Popover
      aria-label={label}
      trigger={
        <div className={sectionButtonClasses}>
          <Icon name="three-dots" />
        </div>
      }
      onToggle={(open) => {
        if (!open) onClose();
        setMenuState("menu");
      }}
    >
      {isSubmenu(activeSubmenu) ? (
        <div className="paragraphs" style={{ width: "300px" }}>
          <h4 style={{ display: "grid", gridTemplateColumns: "1em 1fr 1em" }}>
            <button onClick={() => setMenuState("menu")} aria-label="Go back">
              <Icon name="outline-cheveron-left" />
            </button>
            <div className="text-center">{activeSubmenu.props.heading}</div>
          </h4>
          {activeSubmenu}
        </div>
      ) : (
        <div className="stack" style={{ width: "300px" }}>
          {items.map((item, key) =>
            isSubmenu(item) ? (
              <button onClick={() => setMenuState(key)} key={key}>
                <h5>{item.props.heading}</h5>
                <div>
                  {item.props.text} <Icon name="outline-cheveron-right" />
                </div>
              </button>
            ) : (
              item
            ),
          )}
        </div>
      )}
    </Popover>
  );
};

export const SectionToolbar = ({ children }: { children: React.ReactNode }) => (
  <div
    role="toolbar"
    className="top-4 left-4 flex w-min gap-1 rounded border border-border hover:shadow md:flex-col lg:absolute"
  >
    {children}
  </div>
);

export const SectionLayout = ({
  section,
  children,
  menuItems = [],
}: {
  section: Section;
  children: React.ReactNode;
  menuItems?: React.ReactElement[];
}) => {
  const [state, dispatch] = useReducer();
  const [linkCopied, setLinkCopied] = React.useState(false);
  const updateSection = (updated: Partial<BaseSection>) =>
    dispatch({ type: "update-section", updated: { ...section, ...updated } });
  const saveSection = useSaveSection(section);
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const index = state.sections.indexOf(section);
  const imageUploadSettings = useImageUploadSettings();

  const remove = async () => {
    try {
      await request({
        method: "DELETE",
        url: Routes.profile_section_path(section.id),
        accept: "json",
      });
      dispatch({ type: "remove-section", id: section.id });
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const move = (type: "move-section-up" | "move-section-down") => {
    dispatch({ type, id: section.id });
    requestAnimationFrame(() => scrollRef.current?.scrollIntoView({ block: "center", behavior: "smooth" }));
  };

  const copyLink = () =>
    void navigator.clipboard
      .writeText(new URL(`?section=${section.id}#${section.id}`, window.location.href).toString())
      .then(() => setLinkCopied(true));

  const onClose = () => {
    if (!imageUploadSettings?.isUploading) void saveSection(section);
    setLinkCopied(false);
  };

  return (
    <>
      {section.header && !section.hide_header ? <h2>{section.header}</h2> : null}
      <SectionToolbar>
        <EditorMenu label="Edit section" onClose={onClose}>
          <EditorSubmenu heading="Name" text={section.header}>
            <fieldset>
              <input
                placeholder="Name"
                value={section.header}
                onChange={(e) => updateSection({ header: e.target.value })}
              />
            </fieldset>
            <label>
              <input
                type="checkbox"
                role="switch"
                checked={!section.hide_header}
                onChange={() => updateSection({ hide_header: !section.hide_header })}
              />
              Display above section
            </label>
          </EditorSubmenu>
          {menuItems}
          <button onClick={copyLink}>
            <h5>{linkCopied ? "Copied!" : "Copy link"}</h5>
            <Icon name="link" />
          </button>
          <button onClick={() => void remove()} style={{ color: "rgb(var(--danger))" }}>
            <h5>Remove</h5>
            <Icon name="trash2" />
          </button>
        </EditorMenu>
        <button
          aria-label="Move section up"
          disabled={index === 0}
          onClick={() => move("move-section-up")}
          className={sectionButtonClasses}
        >
          <Icon name="arrow-up" />
        </button>
        <button
          aria-label="Move section down"
          disabled={index === state.sections.length - 1}
          onClick={() => move("move-section-down")}
          className={sectionButtonClasses}
        >
          <Icon name="arrow-down" />
        </button>
      </SectionToolbar>
      <div ref={scrollRef} className="absolute" />
      <div className="mx-auto w-full max-w-6xl">{children}</div>
    </>
  );
};

export const ProductList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <div className="rows" role="list" ref={ref} aria-label="Products">
    {children}
  </div>
));
ProductList.displayName = "ProductList";

const ProductsSettings = ({ section }: { section: ProductsSection }) => {
  const [state, dispatch] = useReducer();
  const updateSection = (updated: Partial<ProductsSection>) =>
    dispatch({ type: "update-section", updated: { ...section, ...updated } });
  const uid = React.useId();

  const [products, setProducts] = React.useState<(EditProduct & { chosen?: boolean })[]>(
    sortBy(state.products, (product) => {
      const index = section.shown_products.indexOf(product.id);
      return index < 0 ? Infinity : index;
    }),
  );

  React.useEffect(
    () =>
      updateSection({
        shown_products: sortBy(section.shown_products, (id) => products.findIndex((product) => product.id === id)),
      }),
    [products],
  );

  return (
    <div className="paragraphs overflow-auto" style={{ maxHeight: "min(100vh, 500px)" }}>
      <fieldset>
        <legend>
          <label htmlFor={`${uid}-defaultProductSort`}>Default sort order</label>
        </legend>
        <TypeSafeOptionSelect
          id={`${uid}-defaultProductSort`}
          value={section.default_product_sort}
          onChange={(key) => updateSection({ default_product_sort: key })}
          options={PROFILE_SORT_KEYS.map((key) => ({
            id: key,
            label: SORT_BY_LABELS[key],
          }))}
        />
      </fieldset>
      <label>
        <input
          type="checkbox"
          role="switch"
          checked={section.show_filters}
          onChange={() => updateSection({ show_filters: !section.show_filters })}
        />
        Show product filters
      </label>
      <label>
        <input
          type="checkbox"
          role="switch"
          checked={section.add_new_products}
          onChange={() => updateSection({ add_new_products: !section.add_new_products })}
        />
        Add new products by default
      </label>
      {products.length > 0 ? (
        <Sortable list={products} setList={setProducts} tag={ProductList} handle="[aria-grabbed]">
          {products.map((product) => {
            const productVisibilityUID = `${uid}-productVisibility-${product.id}`;
            return (
              <label role="listitem" key={product.id} style={{ border: product.chosen ? "var(--border)" : undefined }}>
                <div className="content">
                  {section.default_product_sort === "page_layout" ? <div aria-grabbed={product.chosen} /> : null}
                  <span className="text-singleline">{product.name}</span>
                </div>
                <div className="actions">
                  <input
                    id={productVisibilityUID}
                    type="checkbox"
                    checked={section.shown_products.includes(product.id)}
                    onChange={() => {
                      updateSection({
                        shown_products: section.shown_products.includes(product.id)
                          ? section.shown_products.filter((id) => id !== product.id)
                          : products.flatMap(({ id }) =>
                              product.id === id || section.shown_products.includes(id) ? id : [],
                            ),
                      });
                    }}
                  />
                </div>
              </label>
            );
          })}
        </Sortable>
      ) : null}
    </div>
  );
};

const ProductsSectionView = ({ section }: { section: ProductsSection }) => {
  const [state] = useReducer();
  const params = {
    sort: section.default_product_sort,
    user_id: state.creator_profile.external_id,
    section_id: section.shown_products.length > 0 ? section.id : undefined,
    ids: section.shown_products,
  };
  const [searchState, searchDispatch] = useSearchReducer({ params, results: section.search_results });
  useOnChange(
    () => searchDispatch({ type: "set-params", params }),
    [JSON.stringify(section.shown_products), section.default_product_sort],
  );
  const selectedProductsCount = state.products.filter((product) => section.shown_products.includes(product.id)).length;

  return (
    <SectionLayout
      section={section}
      menuItems={[
        <EditorSubmenu
          key="0"
          heading="Products"
          text={`${selectedProductsCount} ${selectedProductsCount === 1 ? "product" : "products"}`}
        >
          <ProductsSettings section={section} />
        </EditorSubmenu>,
      ]}
    >
      <CardGrid
        hideFilters={!section.show_filters}
        state={searchState}
        dispatchAction={searchDispatch}
        title={
          searchState.results
            ? searchState.results.total > 0
              ? `1-${searchState.results.products.length} of ${searchState.results.total} products`
              : "No products found"
            : "Loading products..."
        }
        currencyCode={state.currency_code}
        defaults={params}
        disableFilters
      />
    </SectionLayout>
  );
};

const PostsSectionView = ({ section }: { section: PostsSection }) => {
  const [state] = useReducer();

  return (
    <SectionLayout section={section}>
      <PostsView posts={state.posts.filter((post) => section.shown_posts.includes(post.id))} />
    </SectionLayout>
  );
};

const RichTextSectionView = ({ section }: { section: RichTextSection }) => {
  const [_, dispatch] = useReducer();
  const [initialValue] = React.useState(section.text);
  const [focused, setFocused] = React.useState(false);
  const saveSection = useSaveSection(section);
  React.useEffect(() => {
    const listener = (e: FocusEvent) => {
      if (e.target !== document.body && e.target instanceof Node && !toolbarRef.current?.contains(e.target))
        setFocused(false);
    };
    window.addEventListener("focusin", listener);
    return () => window.removeEventListener("focusin", listener);
  }, []);
  const editor = useRichTextEditor({
    initialValue,
    placeholder: "Enter text here",
  });
  const toolbarRef = React.useRef<HTMLDivElement>(null);
  const sectionRef = useRefToLatest(section);

  const imageUploadSettings = useImageUploadSettings();
  const isUploadingRef = React.useRef(imageUploadSettings?.isUploading);
  React.useEffect(() => {
    isUploadingRef.current = imageUploadSettings?.isUploading;
  }, [imageUploadSettings?.isUploading]);

  React.useEffect(() => {
    if (!editor) return;
    const update = () => {
      if (isUploadingRef.current) return;

      const text = editor.getJSON();
      dispatch({ type: "update-section", updated: { ...sectionRef.current, text } });
      void saveSection({ ...sectionRef.current, text });
    };
    const debouncedUpdate = debounce(update, 2000);
    editor.on("blur", update);
    editor.on("update", debouncedUpdate);
    return () => {
      editor.off("blur", update);
      editor.off("update", debouncedUpdate);
    };
  }, [editor]);

  return (
    <SectionLayout section={section}>
      {editor ? (
        <div
          ref={toolbarRef}
          style={{ display: "contents" }}
          onMouseDown={() => setFocused(true)}
          // Conditionally rendering this breaks on Safari, so we use hidden instead
          hidden={!editor.isFocused && !focused}
        >
          <RichTextEditorToolbar
            editor={editor}
            productId={section.id}
            // Cancel out the element's height to prevent scroll jumping
            className="border !bg-white !text-black shadow lg:-mt-[calc(1lh+--spacing(4)+2px)]"
          />
        </div>
      ) : null}
      <EditorContent editor={editor} className="rich-text" />
    </SectionLayout>
  );
};

const SubscribeSectionView = ({ section }: { section: SubscribeSection }) => {
  const [state, dispatch] = useReducer();
  const updateSection = (updated: Partial<SubscribeSection>) =>
    dispatch({ type: "update-section", updated: { ...section, ...updated } });
  return (
    <SectionLayout
      section={section}
      menuItems={[
        <EditorSubmenu key="0" heading="Button Label" text={section.button_label}>
          <input
            type="text"
            placeholder="Subscribe"
            aria-label="Button Label"
            value={section.button_label}
            onChange={(evt) => updateSection({ button_label: evt.target.value })}
          />
        </EditorSubmenu>,
      ]}
    >
      <SubscribeView creatorProfile={state.creator_profile} buttonLabel={section.button_label} />
    </SectionLayout>
  );
};

const FeaturedProductSectionView = ({ section }: { section: FeaturedProductSection }) => {
  const uid = React.useId();
  const [state, dispatch] = useReducer();
  const product = state.products.find(({ id }) => id === section.featured_product_id);
  const updateSection = (updated: Partial<FeaturedProductSection>) =>
    dispatch({ type: "update-section", updated: { ...section, ...updated } });

  const [props, setProps] = React.useState<ProductProps | null>(null);
  React.useEffect(() => {
    if (!section.featured_product_id) return;
    setProps(null);
    void getProduct(section.featured_product_id).then(setProps, (e: unknown) => {
      assertResponseError(e);
      showAlert(e.message, "error");
    });
  }, [section.featured_product_id]);

  return (
    <SectionLayout
      section={section}
      menuItems={[
        <EditorSubmenu key="0" heading="Featured Product" text={product?.name}>
          <Select
            inputId={uid}
            options={state.products.map(({ id, name }) => ({ id, label: name }))}
            value={product ? { id: product.id, label: product.name } : null}
            onChange={(option) => updateSection(option ? { featured_product_id: option.id } : {})}
            placeholder="Search products"
            aria-label="Featured Product"
            isMulti={false}
            autoFocus
          />
        </EditorSubmenu>,
      ]}
    >
      {props ? (
        <FeaturedProductView props={props} />
      ) : section.featured_product_id ? (
        <section className="dummy h-128" />
      ) : null}
    </SectionLayout>
  );
};

export const AddSectionButton = ({
  position,
  index,
  className,
}: { index: number } & Pick<PopoverProps, "position" | "className">) => {
  const [open, setOpen] = React.useState(false);
  const [state, dispatch] = useReducer();

  const addSection = (type: Section["type"]) => {
    const add = async () => {
      try {
        const section = (() => {
          const commonProps = { header: "", hide_header: false, product_id: state.product_id };
          switch (type) {
            case "SellerProfileProductsSection":
              return {
                ...commonProps,
                type,
                shown_products: [],
                default_product_sort: "page_layout" as const,
                show_filters: false,
                add_new_products: true,
                search_results: { products: [], total: 0, filetypes_data: [], tags_data: [] },
              };
            case "SellerProfilePostsSection":
              return { ...commonProps, type, shown_posts: state.posts.map((post) => post.id) };
            case "SellerProfileRichTextSection":
              return { ...commonProps, type, text: {} };
            case "SellerProfileSubscribeSection":
              return {
                ...commonProps,
                type,
                header: `Subscribe to receive email updates from ${state.creator_profile.name}.`,
                button_label: "Subscribe",
              };
            case "SellerProfileFeaturedProductSection":
              return { ...commonProps, type };
            case "SellerProfileWishlistsSection":
              return { ...commonProps, type, shown_wishlists: [] };
          }
        })();
        const response = await request({
          method: "POST",
          url: Routes.profile_sections_path(),
          data: section,
          accept: "json",
        });
        const json: unknown = await response.json();
        if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
        const { id } = cast<{ id: string }>(json);
        return { ...section, id };
      } catch (e) {
        if (e instanceof ResponseError) showAlert(e.message, "error");
        throw e;
      }
    };
    dispatch({ type: "add-section", index, section: add() });
  };

  return (
    <Popover
      open={open}
      onToggle={setOpen}
      position={position}
      aria-label="Add section"
      className={classNames(
        "aspect-ratio-1 !absolute -top-px place-self-center",
        { "top-full": position === "top" },
        className,
      )}
      trigger={
        <div className={classNames(sectionButtonClasses, "rounded-b border")}>
          <Icon name="plus" />
        </div>
      }
    >
      <div role="menu" onClick={() => setOpen(false)}>
        <div role="menuitem" onClick={() => addSection("SellerProfileProductsSection")}>
          <Icon name="grid" />
          &ensp; Products
        </div>
        <div role="menuitem" onClick={() => addSection("SellerProfilePostsSection")}>
          <Icon name="envelope-fill" />
          &ensp; Posts
        </div>
        <div role="menuitem" onClick={() => addSection("SellerProfileFeaturedProductSection")}>
          <Icon name="box" />
          &ensp; Featured Product
        </div>
        <div role="menuitem" onClick={() => addSection("SellerProfileRichTextSection")}>
          <Icon name="file-earmark-text" />
          &ensp; Rich text
        </div>
        <div role="menuitem" onClick={() => addSection("SellerProfileSubscribeSection")}>
          <Icon name="solid-bell" />
          &ensp; Subscribe
        </div>
        <div role="menuitem" onClick={() => addSection("SellerProfileWishlistsSection")}>
          <Icon name="file-text-fill" />
          &ensp; Wishlists
        </div>
      </div>
    </Popover>
  );
};

export const EditSection = ({ section }: { section: Section }) => {
  switch (section.type) {
    case "SellerProfileProductsSection":
      return <ProductsSectionView section={section} />;
    case "SellerProfilePostsSection":
      return <PostsSectionView section={section} />;
    case "SellerProfileRichTextSection":
      return <RichTextSectionView section={section} />;
    case "SellerProfileSubscribeSection":
      return <SubscribeSectionView section={section} />;
    case "SellerProfileFeaturedProductSection":
      return <FeaturedProductSectionView section={section} />;
    case "SellerProfileWishlistsSection":
      return <WishlistsSectionView section={section} />;
  }
};
