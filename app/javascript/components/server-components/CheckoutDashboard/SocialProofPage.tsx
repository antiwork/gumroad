import cx from "classnames";
import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import {
  createSocialProof,
  updateSocialProof,
  deleteSocialProof,
  getPagedSocialProofWidgets,
  SocialProofWidget as ImportedSocialProofWidget,
} from "$app/data/social_proof";
import { Thumbnail } from "$app/data/thumbnails";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";
import { writeQueryParams } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { SocialProofCard } from "$app/components/Checkout/SocialProofCard";
import { useSocialProofCardPropsFromPreview } from "$app/components/Checkout/useSocialProofProps";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { ThumbnailEditor } from "$app/components/ProductEdit/ProductTab/ThumbnailEditor";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

// TODO: Get Correct Placeholder
import placeholder from "$assets/images/placeholders/upsells.png";

type SocialProofPlayload = {
  name: string;
  titleText: string;
  description: string;
  ctaText: string;
  ctaType: { id: "button" | "link" | "none"; label: string };
  image: { id: "product" | "custom" | "icon" | "none"; label: string };
  icon: string;
  iconColor: string;
  selectedProductIds: string[];
  universal: boolean;
  status: string;
};

export type SortKey = "name" | "clicks" | "conversion" | "revenue" | "status";

// TODO: make this type more specific if possible
// make this union discriminative
type CtaType = { id: "button" | "link" | "none"; label: "Button" | "Link" | "None" };
type ImageType = {
  id: "product" | "custom" | "icon" | "none";
  label: "Product image" | "Custom image" | "Icon" | "None";
};
type VisibilityType = {
  id: "all" | "new" | "returning";
  label: "All visitors" | "New visitors" | "Returning visitors";
};

export type QueryParams = {
  sort: Sort<SortKey> | null;
  query: string | null;
  page: number | null;
};

const extractParams = (rawParams: URLSearchParams): QueryParams => {
  const column = rawParams.get("column");
  let sort: Sort<SortKey> | null = null;
  switch (column) {
    case "name":
    case "clicks":
    case "conversion":
    case "revenue":
    case "status":
      sort = {
        direction: rawParams.get("sort") === "desc" ? "desc" : "asc",
        key: column,
      };
      break;
    default:
      break;
  }
  const query = rawParams.get("query");
  const pageStr = rawParams.get("page");
  const page = pageStr ? parseInt(pageStr, 10) : 1;
  return {
    query: query ? decodeURIComponent(query) : "",
    sort,
    page,
  };
};

export type SocialProofWidget = ImportedSocialProofWidget;

const SocialProofPage = ({
  pages,
  products,
  social_proof_widgets,
  pagination: initialPagination,
}: {
  pages: Page[];
  products: Product[];
  social_proof_widgets: SocialProofWidget[];
  pagination?: PaginationProps | undefined | null;
}) => {
  const loggedInUser = useLoggedInUser();
  const [view, setView] = React.useState<"list" | "create" | "edit">("list");
  const originalLocation = useOriginalLocation();
  const initialQueryParams = extractParams(new URL(originalLocation).searchParams);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, setSort);
  const [isSaving, setIsSaving] = React.useState(false);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const [isLoading, setIsLoading] = React.useState(false);
  const [searchQuery, setSearchQuery] = React.useState<string | null>(initialQueryParams.query);
  const [selectedSocialProofWidgetId, setSelectedSocialProofWidgetId] = React.useState<number | null>(null);
  const [editingSocialProofWidgetId, setEditingSocialProofWidgetId] = React.useState<number | null>(null);
  const [popoverSocialProofWidgetId, setPopoverSocialProofWidgetId] = React.useState<number | null>(null);

  const handleSave = async (formData: SocialProofPlayload) => {
    try {
      setIsSaving(true);
      await createSocialProof(formData);
      showAlert("Successfully created widget!", "success");
      // Refresh the widget list
      loadSocialProofWidgets({ page: 1, query: searchQuery, sort });
      setEditingSocialProofWidgetId(null);
      setView("list");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSaving(false);
  };

  const handleUpdate = async (formData: SocialProofPlayload) => {
    if (!editingSocialProofWidget) return;
    try {
      setIsSaving(true);
      await updateSocialProof(editingSocialProofWidget.id, formData);
      showAlert("Successfully updated widget!", "success");
      // Refresh the widget list
      loadSocialProofWidgets({ page: 1, query: searchQuery, sort });
      setEditingSocialProofWidgetId(null);
      setView("list");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSaving(false);
  };

  const setUrlQueryParams = (params: QueryParams): void => {
    const currentUrl = new URL(window.location.href);
    const newUrl = writeQueryParams(currentUrl, {
      page: params.page?.toString() || null,
      query: params.query || null,
      sort: params.sort?.direction || null,
      column: params.sort?.key || null,
    });
    if (newUrl.toString() !== window.location.href) window.history.pushState(params, document.title, newUrl.toString());
  };

  const loadSocialProofWidgets = asyncVoid(
    async ({ page, query, sort, keepUrl }: QueryParams & { keepUrl?: boolean }) => {
      try {
        activeRequest.current?.cancel();
        setIsLoading(true);

        if (!keepUrl)
          setUrlQueryParams({
            query,
            sort,
            page: (pagination?.pages ?? 0) > 1 ? page : null,
          });

        const request = getPagedSocialProofWidgets(page || 1, query, sort);
        activeRequest.current = request;

        const { social_proof_widgets: socialProofWidgets, pagination: newPagination } = await request.response;
        setState({ socialProofWidgets, pagination: newPagination });
        setIsLoading(false);
        activeRequest.current = null;
      } catch (e) {
        if (e instanceof AbortError) return;
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    },
  );

  const debouncedLoadSocialProofWidgets = useDebouncedCallback(
    () => loadSocialProofWidgets({ page: 1, query: searchQuery, sort }),
    300,
  );

  const [{ socialProofWidgets, pagination }, setState] = React.useState<{
    socialProofWidgets: SocialProofWidget[];
    pagination: PaginationProps | null | undefined;
  }>({
    socialProofWidgets: social_proof_widgets,
    pagination: initialPagination,
  });

  const selectedSocialProofWidget = socialProofWidgets.find(({ id }) => id === selectedSocialProofWidgetId);
  const editingSocialProofWidget = socialProofWidgets.find(({ id }) => id === editingSocialProofWidgetId);

  return view === "list" ? (
    <Layout
      currentPage="social"
      pages={pages}
      actions={
        <>
          <Popover
            open={isSearchPopoverOpen}
            onToggle={setIsSearchPopoverOpen}
            aria-label="Search"
            trigger={
              <div className="button">
                <Icon name="solid-search" />
              </div>
            }
          >
            <div className="input">
              <Icon name="solid-search" />
              <input
                ref={searchInputRef}
                type="text"
                placeholder="Search"
                value={searchQuery ?? ""}
                onChange={(evt) => {
                  setSearchQuery(evt.target.value);
                  debouncedLoadSocialProofWidgets();
                }}
              />
            </div>
          </Popover>
          <Button
            color="accent"
            onClick={() => {
              setEditingSocialProofWidgetId(null);
              setView("create");
            }}
            disabled={!loggedInUser?.policies.checkout_form.update}
          >
            New widget
          </Button>
        </>
      }
    >
      <section className="paragraphs">
        {socialProofWidgets.length > 0 ? (
          <>
            <table aria-live="polite" aria-busy={isLoading}>
              <thead>
                <tr>
                  <th {...thProps("name")} title="Sort by Name" style={{ width: "30%" }}>
                    Widget
                  </th>
                  <th {...thProps("clicks")} title="Sort by Clicks">
                    Clicks
                  </th>
                  <th {...thProps("conversion")} title="Sort by Conversion">
                    Conversion
                  </th>
                  <th {...thProps("revenue")} title="Sort by Revenue">
                    Revenue
                  </th>
                  <th {...thProps("status")} title="Sort by Status">
                    Status
                  </th>
                </tr>
              </thead>

              <tbody>
                {socialProofWidgets.map((socialProofWidget) => (
                  <tr
                    key={socialProofWidget.id}
                    aria-selected={socialProofWidget.id === selectedSocialProofWidgetId}
                    onClick={() => setSelectedSocialProofWidgetId(socialProofWidget.id)}
                  >
                    <td style={{ width: "30%" }}>
                      <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                        <b>{socialProofWidget.name}</b>
                      </div>
                    </td>

                    <td style={{ whiteSpace: "nowrap" }}>{socialProofWidget.clicks}</td>
                    <td style={{ whiteSpace: "nowrap" }}>{socialProofWidget.conversion_rate}</td>

                    <td>{socialProofWidget.revenue}</td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      <div style={{ display: "grid", gridTemplateColumns: "min-content 1fr", gap: "var(--spacer-2)" }}>
                        {socialProofWidget.status === "published" ? (
                          <Icon name="circle-fill" />
                        ) : (
                          <Icon name="circle" />
                        )}
                        {socialProofWidget.status}
                      </div>
                    </td>
                    <td>
                      <div className="actions">
                        <Button
                          aria-label="Edit"
                          disabled={!socialProofWidget.can_update || isLoading}
                          onClick={() => {
                            setEditingSocialProofWidgetId(socialProofWidget.id);
                            setView("edit");
                          }}
                        >
                          <Icon name="pencil" />
                        </Button>
                        <Popover
                          open={popoverSocialProofWidgetId === socialProofWidget.id}
                          onToggle={(open) => setPopoverSocialProofWidgetId(open ? socialProofWidget.id : null)}
                          aria-label="Open social proof widget action menu"
                          trigger={
                            <div className="button">
                              <Icon name="three-dots" />
                            </div>
                          }
                        >
                          <div role="menu">
                            <div
                              role="menuitem"
                              inert={!socialProofWidget.can_update || isLoading}
                              onClick={() => {
                                setEditingSocialProofWidgetId(socialProofWidget.id);
                                setView("create");
                              }}
                            >
                              <Icon name="outline-duplicate" />
                              &ensp;Duplicate
                            </div>
                            <div
                              role="menuitem"
                              className="danger"
                              inert={!socialProofWidget.can_update || isLoading}
                              onClick={asyncVoid(async () => {
                                try {
                                  setIsLoading(true);
                                  await deleteSocialProof(socialProofWidget.id);
                                  showAlert("Widget deleted successfully!", "success");
                                  // Refresh the widget list
                                  loadSocialProofWidgets({ page: 1, query: searchQuery, sort });
                                } catch (e) {
                                  assertResponseError(e);
                                  showAlert(e.message, "error");
                                }
                                setIsLoading(false);
                              })}
                            >
                              <Icon name="trash2" />
                              &ensp;Delete
                            </div>
                          </div>
                        </Popover>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {pagination?.pages && pagination.pages > 1 ? (
              <Pagination
                onChangePage={(newPage) => loadSocialProofWidgets({ page: newPage, query: searchQuery, sort })}
                pagination={pagination}
              />
            ) : null}
          </>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Use social proof to build trust and boost conversions</h2>
            Let your product page do the talking. Show off what's happening and get more people clicking.
            <Button
              color="accent"
              onClick={() => {
                setEditingSocialProofWidgetId(null);
                setView("create");
              }}
            >
              New widget
            </Button>
            <a
              href="#"
              data-helper-prompt="What are social proof widgets and how can I use them to increase my revenue?"
            >
              Learn more about social proof.
            </a>
          </div>
        )}
        {selectedSocialProofWidget ? (
          <aside>
            <header>
              <h2>{selectedSocialProofWidget.name}</h2>
              <button className="close" aria-label="Close" onClick={() => setSelectedSocialProofWidgetId(null)} />
            </header>
            <section className="stack">
              <h3>Details</h3>
              <div>
                <h5>Clicks</h5>
                {selectedSocialProofWidget.clicks}
              </div>
              <div>
                <h5>Conversion</h5>
                {selectedSocialProofWidget.conversion_rate}
              </div>
              <div>
                <h5>Revenue</h5>
                {selectedSocialProofWidget.revenue}
              </div>
              <div>
                <h5>Status</h5>
                {selectedSocialProofWidget.status}
              </div>
            </section>
            <section
              style={{ display: "grid", gap: "var(--spacer-4)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}
            >
              <Button
                onClick={() => {
                  setEditingSocialProofWidgetId(selectedSocialProofWidget.id);
                  setView("create");
                }}
                disabled={!selectedSocialProofWidget.can_update || isLoading}
              >
                Duplicate
              </Button>
              <Button
                onClick={() => {
                  setEditingSocialProofWidgetId(selectedSocialProofWidget.id);
                  setView("edit");
                }}
                disabled={!selectedSocialProofWidget.can_update || isLoading}
              >
                Edit
              </Button>
              <Button
                color="danger"
                onClick={asyncVoid(async () => {
                  try {
                    setIsLoading(true);
                    await deleteSocialProof(selectedSocialProofWidget.id);
                    showAlert("Widget deleted successfully!", "success");
                    loadSocialProofWidgets({ page: 1, query: searchQuery, sort });
                    setSelectedSocialProofWidgetId(null);
                  } catch (e) {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  }
                  setIsLoading(false);
                })}
                disabled={!selectedSocialProofWidget.can_update || isLoading}
              >
                {isLoading ? "Deleting..." : "Delete"}
              </Button>
            </section>
          </aside>
        ) : null}
      </section>
    </Layout>
  ) : view === "edit" ? (
    <Form
      title="Edit widget"
      submitLabel={isSaving ? "Saving changes..." : "Save changes"}
      socialProofWidget={editingSocialProofWidget}
      products={products}
      setView={setView}
      save={handleUpdate}
      isLoading={isSaving}
      onCancel={() => setEditingSocialProofWidgetId(null)}
    />
  ) : (
    <Form
      title="Create widget"
      submitLabel={isSaving ? "Adding widget..." : "Add widget"}
      socialProofWidget={editingSocialProofWidget}
      products={products}
      setView={setView}
      save={handleSave}
      isLoading={isSaving}
      onCancel={() => setEditingSocialProofWidgetId(null)}
    />
  );
};

export default register({ component: SocialProofPage, propParser: createCast() });

type Product = {
  id: string;
  name: string;
  url: string;
  is_tiered_membership: boolean;
  archived: boolean;
  //   title: string;
  //   description: string;
};

const Form = ({
  title,
  submitLabel,
  socialProofWidget,
  products,
  setView,
  save,
  isLoading,
  onCancel,
}: {
  title: string;
  submitLabel?: string;
  socialProofWidget?: SocialProofWidget | undefined;
  products: Product[];
  setView: React.Dispatch<React.SetStateAction<"list" | "create" | "edit">>;
  save: (formData: SocialProofPlayload) => Promise<void>;
  isLoading: boolean;
  onCancel?: () => void;
}) => {
  const [name, setName] = React.useState(socialProofWidget?.name ?? "");
  const [titleText, setTitleText] = React.useState(socialProofWidget?.title ?? "");
  const [description, setDescription] = React.useState(socialProofWidget?.description ?? "");
  const [ctaText, setCtaText] = React.useState(socialProofWidget?.cta_text ?? "");

  const getCtaType = (): CtaType => {
    const type = socialProofWidget?.cta_type;
    if (type === "button") return { id: "button", label: "Button" };
    if (type === "link") return { id: "link", label: "Link" };
    if (type === "none") return { id: "none", label: "None" };
    return { id: "button", label: "Button" };
  };
  const [ctaType, setCtaType] = React.useState<CtaType>(getCtaType());

  const getImageType = (): ImageType => {
    const type = socialProofWidget?.image_type;
    if (type === "product") return { id: "product", label: "Product image" };
    if (type === "custom") return { id: "custom", label: "Custom image" };
    if (type === "icon") return { id: "icon", label: "Icon" };
    if (type === "none") return { id: "none", label: "None" };
    return { id: "product", label: "Product image" };
  };
  const [image, setImage] = React.useState<ImageType>(getImageType());

  const [thumbnail, setThumbnail] = React.useState<Thumbnail | null>(null);
  const [icon, setIcon] = React.useState<string>(socialProofWidget?.icon_name ?? "heart-fill");
  const [iconColor, setIconColor] = React.useState(socialProofWidget?.icon_color ?? "#FFB800");
  const [universal, setUniversal] = React.useState(false);
  const [selectedProductIds, setSelectedProductIds] = React.useState<{ value: string[]; error?: boolean }>({
    value: [],
  });
  const [visibility, setVisibility] = React.useState<VisibilityType>({ id: "all", label: "All visitors" });
  const [status, setStatus] = React.useState(socialProofWidget?.status ?? "unpublished");

  const selectedProducts = products.filter(({ id }) => selectedProductIds.value.includes(id));

  const uid = React.useId();

  const handleSubmit = async () => {
    const formData = {
      name,
      titleText,
      description,
      ctaText,
      ctaType,
      image,
      icon,
      iconColor,
      selectedProductIds: universal ? [] : selectedProductIds.value,
      universal,
      status,
    };
    await save(formData);
  };

  const handleTogglePublish = async () => {
    const newStatus = status === "published" ? "unpublished" : "published";
    const formData = {
      name,
      titleText,
      description,
      ctaText,
      ctaType,
      image,
      icon,
      iconColor,
      selectedProductIds: universal ? [] : selectedProductIds.value,
      universal,
      status: newStatus,
    };
    await save(formData);
    setStatus(newStatus);
  };

  return (
    <div className="fixed-aside" style={{ display: "contents" }}>
      <header className="sticky-top">
        <h1>{title}</h1>
        <div className="actions">
          <Button
            onClick={() => {
              onCancel?.();
              setView("list");
            }}
          >
            <Icon name="x-square" />
            Cancel
          </Button>
          <Button type="submit" color="black" onClick={() => void handleSubmit()} disabled={isLoading}>
            {status === "published" ? submitLabel || "Save changes" : submitLabel || "Save as draft"}
          </Button>
          <Button color="accent" onClick={() => void handleTogglePublish()} disabled={isLoading}>
            {status === "published" ? "Unpublish" : "Publish"}
          </Button>
        </div>
      </header>
      <main className="squished">
        <form>
          <section className="paragraphs">
            <fieldset className={cx({ danger: false })}>
              <legend>
                <label htmlFor="name">Widget name</label>
              </legend>
              <input
                type="text"
                id="name"
                placeholder="Community members"
                value={name}
                onChange={(evt) => setName(evt.target.value)}
                aria-invalid={false}
              />
            </fieldset>
            <fieldset className={cx({ danger: selectedProductIds.error })}>
              <legend>
                <label htmlFor={`${uid}products`}>Products</label>
              </legend>
              <Select
                inputId={`${uid}products`}
                instanceId={`${uid}products`}
                options={products
                  .filter((product) => !product.archived)
                  .map((product) => ({ id: product.id, label: product.name }))}
                value={selectedProducts.map(({ id, name: label }) => ({
                  id,
                  label,
                }))}
                isMulti
                isClearable
                placeholder="Products to which this discount will apply"
                onChange={(selectedIds) => {
                  setSelectedProductIds({ value: selectedIds.map(({ id }) => id) });
                }}
                isDisabled={universal}
                aria-invalid={selectedProductIds.error}
              />
              <label>
                <input
                  type="checkbox"
                  checked={universal}
                  onChange={(evt) => {
                    setUniversal(evt.target.checked);
                    setSelectedProductIds({ value: [] });
                  }}
                  aria-invalid={selectedProductIds.error}
                />
                All products
              </label>
            </fieldset>
          </section>
          <section className="paragraphs">
            <h2>Message</h2>
            <p>
              Click on the buttons below to quickly add them to your title, description, or call to action. This will
              dynamically update your widget.{" "}
              <a
                // TODO: find the correct link
                href="#"
                target="_blank"
                rel="noreferrer"
              >
                Learn more
              </a>
            </p>
            <fieldset className={cx({ danger: false })}>
              <legend>
                <label htmlFor="title">Title</label>
              </legend>
              <input
                type="text"
                id="title"
                placeholder="Join the community"
                value={titleText}
                onChange={(evt) => setTitleText(evt.target.value)}
                aria-invalid={false}
              />
            </fieldset>
            <fieldset className={cx({ danger: false })}>
              <legend>
                <label htmlFor="description">Description</label>
              </legend>
              <textarea
                id="description"
                placeholder="Get limited-time access to our community"
                value={description}
                onChange={(evt) => setDescription(evt.target.value)}
                aria-invalid={false}
              />
            </fieldset>
            <fieldset className={cx({ danger: false })}>
              <legend>
                <label htmlFor="cta">Call to action</label>
              </legend>
              <input
                type="text"
                id="cta"
                placeholder="Join now"
                value={ctaText}
                onChange={(evt) => setCtaText(evt.target.value)}
                aria-invalid={false}
              />
            </fieldset>
            <fieldset className={cx({ danger: false })}>
              <legend>
                <label htmlFor="cta-type">Call to action</label>
              </legend>
              <Select
                inputId="cta-type"
                instanceId="cta-type"
                options={[
                  { id: "button", label: "Button" },
                  { id: "link", label: "Link" },
                  { id: "none", label: "None" },
                ]}
                isMulti={false}
                value={{ id: ctaType.id, label: ctaType.label }}
                onChange={(selected) => {
                  setCtaType(cast(selected));
                }}
              />
            </fieldset>
          </section>
          <section className="paragraphs">
            <h2>Image</h2>
            <fieldset>
              <legend>
                <label htmlFor="image">Image</label>
              </legend>
              <Select
                inputId="image"
                instanceId="image"
                isMulti={false}
                options={[
                  { id: "product", label: "Product image" },
                  { id: "custom", label: "Custom image" },
                  { id: "none", label: "None" },
                  { id: "icon", label: "Icon" },
                ]}
                value={image}
                onChange={(selected) => {
                  setImage(cast(selected));
                }}
              />
              {image.id === "custom" && (
                <ThumbnailEditor
                  covers={[]}
                  thumbnail={thumbnail}
                  setThumbnail={setThumbnail}
                  permalink=""
                  nativeType="bundle"
                />
              )}
              {image.id === "icon" && (
                <>
                  <div>
                    <Button onClick={() => setIcon("heart-fill")}>
                      <Icon name="heart-fill" />
                    </Button>
                  </div>
                  <fieldset>
                    <legend>
                      <label htmlFor={`${uid}-iconColor`}>Icon color</label>
                    </legend>
                    <div className="color-picker">
                      <input
                        id={`${uid}-iconColor`}
                        value={iconColor}
                        type="color"
                        onChange={(evt) => setIconColor(evt.target.value)}
                      />
                    </div>
                  </fieldset>
                </>
              )}
            </fieldset>
          </section>

          <section className="paragraphs">
            <h2>Settings</h2>
            <fieldset>
              <legend>
                <label htmlFor="visibility">Widget will be visible to...</label>
              </legend>
              <Select
                inputId="visibility"
                instanceId="visibility"
                options={[
                  { id: "all", label: "All visitors" },
                  { id: "new", label: "New visitors" },
                  { id: "returning", label: "Returning visitors" },
                ]}
                value={visibility}
                onChange={(selected) => {
                  setVisibility(cast(selected));
                }}
              />
            </fieldset>
          </section>
        </form>
      </main>
      <Preview
        name={name}
        titleText={titleText}
        description={description}
        ctaText={ctaText}
        ctaType={ctaType}
        image={image}
        icon={icon}
        iconColor={iconColor}
      />
    </div>
  );
};

const Preview = ({
  titleText,
  description,
  ctaText,
  ctaType,
  image,
  icon,
  iconColor,
}: {
  name: string;
  titleText: string;
  description: string;
  ctaText: string;
  ctaType: CtaType;
  image: ImageType;
  icon: string;
  iconColor: string;
}) => {
  const socialProofCardProps = useSocialProofCardPropsFromPreview({
    titleText,
    description,
    ctaText,
    ctaType: ctaType.id,
    image,
    icon,
    iconColor,
  });

  return (
    <aside aria-label="Preview">
      <header>
        <h2>Preview</h2>
        <WithTooltip tip="Preview">
          {/* TODO: add link */}
          <Button onClick={() => {}}>
            <Icon name="arrow-diagonal-up-right" />
          </Button>
        </WithTooltip>
      </header>
      <div className="paragraphs flex aspect-square items-center justify-center rounded border border-black">
        <SocialProofCard {...socialProofCardProps} />
      </div>
    </aside>
  );
};
