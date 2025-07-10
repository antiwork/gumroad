import * as React from "react";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import {
  createSocialProofWidget,
  deleteSocialProofWidget,
  getPagedSocialProofWidgets,
  getSocialProofWidget,
  updateSocialProofWidget,
  SocialProofWidgetPayload,
  Widget,
} from "$app/data/social_proof_widgets";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { createCast } from "ts-safe-cast";
import { AbortError, assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { Icon } from "$app/components/Icons";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { IconSelector } from "$app/components/SocialProofWidget/IconSelector";
import { ImageUpload } from "$app/components/SocialProofWidget/ImageUpload";
import { CartItem } from "$app/components/Checkout/cartState";
import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";
import { WidgetPreview } from "$app/components/SocialProofWidget/WidgetPreview";
import { WidgetFormData, ProductOption, ImageTypeOption, CtaTypeOption, IconOption, SocialProofWidgetData } from "$app/components/SocialProofWidget/types";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";


// TODO: Need to update this to a proper placeholder image

import placeholder from "$assets/images/placeholders/discounts.png";

export type SortKey = "name" | "updated_at" | "status";

type Props = {
  widgets: Widget[];
  pagination: PaginationProps;
  available_products: ProductOption[];
  image_type_options: ImageTypeOption[];
  cta_type_options: CtaTypeOption[];
  icon_options: IconOption[];
  pages: Page[];
};

const SocialProofPage = ({ 
  widgets: initialWidgets, 
  pagination: initialPagination,
  available_products,
  image_type_options,
  cta_type_options,
  icon_options,
  pages
}: Props) => {
  const loggedInUser = useLoggedInUser();
  const isReadOnly = !loggedInUser?.policies.upsell?.create;

  const [widgets, setWidgets] = React.useState<Widget[]>(initialWidgets);
  const [pagination, setPagination] = React.useState(initialPagination);
  const [drawerOpen, setDrawerOpen] = React.useState<boolean>(false);
  const [query, setQuery] = React.useState<string>("");
  const [selectedWidgetId, setSelectedWidgetId] = React.useState<string | null>(null);
  const selectedWidget = widgets.find(({ id }) => id === selectedWidgetId) || null;
  
  const [view, setView] = React.useState<"list" | "create" | "edit">("list");
  const [isLoading, setIsLoading] = React.useState(false);
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, (newSort) => {
    refreshWidgets({ page: 1, query, sort: newSort });
    setSort(newSort);
  });


  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);

  const searchDebounced = useDebouncedCallback((query: string) => {
    const currentUrl = new URL(window.location.href);
    const newUrl = new URL(currentUrl);
    if (query) {
      newUrl.searchParams.set('query', query);
    } else {
      newUrl.searchParams.delete('query');
    }
    newUrl.searchParams.delete('page');
    window.history.pushState({}, '', newUrl.toString());
    void refreshWidgets({ query });
  }, 500);

  const refreshWidgets = async (params: { query?: string; page?: number; sort?: Sort<SortKey> | null } = {}) => {
    if (isLoading) return;
    setIsLoading(true);

    try {
      const response = await getPagedSocialProofWidgets({
        query: params.query ?? query,
        page: params.page ?? 1,
      });
      const { widgets, pagination } = await response.response;
      setWidgets(widgets);
      setPagination(pagination);
    } catch (error) {
      if (error instanceof AbortError) return;
      assertResponseError(error);
      showAlert("Failed to load widgets. Please try again.", "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleCreate = async (data: SocialProofWidgetPayload) => {
    try {
      setIsLoading(true);
      await createSocialProofWidget(data);
      const action = data.status === "published" ? "published" : "saved";
      showAlert(`Widget ${action} successfully!`, "success");
      setView("list");
      void refreshWidgets();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };
  
  const handleUpdate = async (data: SocialProofWidgetPayload) => {
    if (!selectedWidgetId) return;
    try {
      setIsLoading(true);
      await updateSocialProofWidget(selectedWidgetId, data);
      const action = data.status === "published" ? "published" : "saved";
      showAlert(`Widget ${action} successfully!`, "success");
      setView("list");
      void refreshWidgets();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleDelete = async () => {
    if (!selectedWidgetId) return;
    try {
      setIsLoading(true);
      await deleteSocialProofWidget(selectedWidgetId);
      setSelectedWidgetId(null);
      showAlert("Widget deleted successfully!", "success");
      void refreshWidgets();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleDuplicate = async (widgetId: string) => {
    const widget = widgets.find(w => w.id === widgetId);
    if (!widget) return;

    try {
      setIsLoading(true);
      // Create a copy of the widget with a new name
      const duplicateData: SocialProofWidgetPayload = {
        name: `${widget.name} (Copy)`,
        universal: widget.universal,
        title: "", // Will be populated from the original widget
        description: "",
        cta_text: "",
        cta_type: widget.cta_type as "button" | "link" | "none",
        status: "unpublished", // always creating duplicates as unpublished
        image_type: widget.image_type,
        product_ids: widget.universal ? [] : [],
        custom_image_signed_blob_id: null,
        icon_color: widget.image_type.startsWith("icon_") ? widget.icon_color : null
      };

      // Load the full widget data to get the content
      const editProps = await getSocialProofWidget(widget.id);
      duplicateData.title = editProps.title || "";
      duplicateData.description = editProps.description || "";
      duplicateData.cta_text = editProps.cta_text || "";
      duplicateData.product_ids = editProps.product_ids || [];

      await createSocialProofWidget(duplicateData);
      showAlert("Widget duplicated successfully!", "success");
      void refreshWidgets();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleCancel = () => {
    setView("list");
    setSelectedWidgetId(null);
  };

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  if (view === "create") {
    return (
      <WidgetForm
        title="Create Widget"
        widget={null}
        onSave={handleCreate}
        onCancel={handleCancel}
        availableProducts={available_products}
        imageTypeOptions={image_type_options}
        ctaTypeOptions={cta_type_options}
        iconOptions={icon_options}
      />
    );
  }

  if (view === "edit") {
    return (
      <WidgetForm
        title="Edit Widget"
        widget={selectedWidget}
        onSave={handleUpdate}
        onCancel={handleCancel}
        availableProducts={available_products}
        imageTypeOptions={image_type_options}
        ctaTypeOptions={cta_type_options}
        iconOptions={icon_options}
      />
    );
  }

  return (
    <Layout
      currentPage="social_proof_widgets"
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
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  searchDebounced(e.target.value);
                }}
              />
            </div>
          </Popover>
          <Button color="accent" onClick={() => setView("create")} disabled={isReadOnly}>
            New widget
          </Button>
        </>
      }
    >
      <section className="paragraphs">
        {widgets.length === 0 && !query ? (
          <div className="placeholder">
            <img src={placeholder} alt="No social proof widgets" />
            <h3>Add social proof to your checkout</h3>
            <p>Show customers that others have purchased your products to increase conversions.</p>
            <Button color="primary" onClick={() => setView("create")}>
              Create your first widget
            </Button>
          </div>
        ) : widgets.length > 0 ? (
          <>
            <table aria-busy={isLoading} aria-label="Social Proof Widgets">
              <thead>
                <tr>
                  <th {...thProps("name")}>Widget</th>
                  <th {...thProps("status")}>Status</th>
                  <th {...thProps("updated_at")}>Last Updated</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {widgets.map((widget) => (
                  <tr key={widget.id}>
                    <td>
                      <div>
                        <div>
                          <b>{widget.name}</b>
                        </div>
                        <small>{widget.universal ? "All products" : `${widget.product_count} products`}</small>
                      </div>
                    </td>
                    <td data-label="Status" style={{ whiteSpace: "nowrap" }}>
                      {(() => {
                        const isPublished = widget.status === "published";
                        return isPublished ? (
                          <>
                            <Icon name="circle-fill" /> Published
                          </>
                        ) : (
                          <>
                            <Icon name="circle" /> Unpublished
                          </>
                        );
                      })()}
                    </td>
                    <td>{new Date(widget.updated_at).toLocaleDateString()}</td>
                    <td>
                      <div className="actions">
                        <Button
                          aria-label="Edit"
                          disabled={isLoading || isReadOnly}
                          onClick={() => {
                            setDrawerOpen(true);
                            setSelectedWidgetId(widget.id)
                          }}
                        >
                          <Icon name="pencil" />
                        </Button>
                        <Popover
                          aria-label="Open widget action menu"
                          trigger={
                            <div className="button">
                              <Icon name="three-dots" />
                            </div>
                          }
                        >
                          <div role="menu">
                            <div 
                              role="menuitem" 
                              onClick={() => void handleDuplicate(widget.id)}
                            >
                              <Icon name="outline-duplicate" />
                              &ensp;Duplicate
                            </div>
                            <div
                              className="danger"
                              role="menuitem"
                              onClick={() => {
                                setSelectedWidgetId(widget.id);
                                void handleDelete();
                              }}
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
            <Pagination
              pagination={pagination}
              onChangePage={(page) => void refreshWidgets({ page })}
            />
          </>
        ) : (
          <div className="placeholder">
            <Icon name="solid-search" />
            <p>No widgets match your search.</p>
          </div>
        )}
        {drawerOpen && selectedWidget && (
          <WidgetDrawer
            selectedWidget={selectedWidget}
            onCreate={() => setView("create")}
            onEdit={() => setView("edit")}
            onDelete={handleDelete}
            onClose={() => {
              setDrawerOpen(false);
              setSelectedWidgetId(null);
            }}
            isLoading={isLoading}
          />
        )}
      </section>
    </Layout>
  );
};

const WidgetDrawer = ({
  selectedWidget,
  onCreate,
  onEdit,
  onDelete,
  onClose,
  isLoading,
}: {
  selectedWidget: Widget;
  onCreate: () => void;
  onEdit: () => void;
  onDelete: () => void;
  onClose: () => void;
  isLoading: boolean;
}) => {
  const loggedInUser = useLoggedInUser();
  const isReadOnly = !loggedInUser?.policies.upsell?.create;

  return (
    <aside className="fixed-aside">
      <header>
        <h2>{selectedWidget.name}</h2>
        <button className="close" aria-label="Close" onClick={onClose} />
      </header>
      <section className="stack">
        <h3>Details</h3>
        <div>
          <h5>Status</h5>
          {selectedWidget.status === "published" ? "Published" : "Unpublished"}
        </div>
        <div>
          <h5>Type</h5>
          {selectedWidget.cta_type}
        </div>
        <div>
          <h5>Image Type</h5>
          {selectedWidget.image_type}
        </div>
        <div>
          <h5>Products</h5>
          {selectedWidget.product_count} products
        </div>
        <div>
          <h5>Last Updated</h5>
          {new Date(selectedWidget.updated_at).toLocaleDateString()}
        </div>
      </section>
      <section className="grid grid-cols-3 gap-4">
        <Button onClick={onCreate} disabled={isLoading || isReadOnly}>
          Duplicate
        </Button>
        <Button onClick={onEdit} disabled={isLoading || isReadOnly}>
          Edit
        </Button>
        <Button onClick={onDelete} color="danger" disabled={isLoading || isReadOnly}>
          {isLoading ? "Deleting..." : "Delete"}
        </Button>
      </section>
    </aside>
  );
};

const WidgetForm = ({
  title,
  widget,
  onSave,
  onCancel,
  availableProducts,
  imageTypeOptions,
  ctaTypeOptions,
  iconOptions,
}: {
  title: string;
  widget: Widget | null;
  onSave: (data: SocialProofWidgetPayload) => Promise<void>;
  onCancel: () => void;
  availableProducts: ProductOption[];
  imageTypeOptions: ImageTypeOption[];
  ctaTypeOptions: CtaTypeOption[];
  iconOptions: IconOption[];
}) => {
  const uid = React.useId();
  
  // Form state
  const [name, setName] = React.useState(widget?.name ?? "");
  const [universal, setUniversal] = React.useState(widget?.universal ?? false);
  const [widgetTitle, setWidgetTitle] = React.useState("");
  const [description, setDescription] = React.useState("");
  const [ctaText, setCtaText] = React.useState("");
  const [ctaType, setCtaType] = React.useState<"button" | "link" | "none">("none");
  const [imageType, setImageType] = React.useState("product_thumbnail");
  const [selectedProductIds, setSelectedProductIds] = React.useState<string[]>([]);
  const [customImageUrl, setCustomImageUrl] = React.useState<string | null>(null);
  const [customImageBlobId, setCustomImageBlobId] = React.useState<string | null>(null);
  const [selectedIcon, setSelectedIcon] = React.useState<string | null>(null);
  const [iconColor, setIconColor] = React.useState("#000000");

  const titleInputRef = React.useRef<HTMLInputElement>(null);
  const descriptionInputRef = React.useRef<HTMLTextAreaElement>(null);
  const ctaTextInputRef = React.useRef<HTMLInputElement>(null);

  const [lastFocusedField, setLastFocusedField] = React.useState<'title' | 'description' | 'cta' | null>(null);
  
  const handleFieldFocus = (fieldType: 'title' | 'description' | 'cta') => {
    setLastFocusedField(fieldType);
  };

  const handleVariableButtonClick = (text: string) => {
    const variableText = `[${text.toLowerCase().replace(/ /g, '_')}]`;
    
    switch (lastFocusedField) {
      case 'title':
        insertTextAtCursor(titleInputRef.current, variableText, setWidgetTitle);
        break;
      case 'description':
        insertTextAtCursor(descriptionInputRef.current, variableText, setDescription);
        break;
      case 'cta':
        insertTextAtCursor(ctaTextInputRef.current, variableText, setCtaText);
        break;
      default:
        insertTextAtCursor(titleInputRef.current, variableText, setWidgetTitle);
        setLastFocusedField('title');
        break;
    }
  };

  const insertTextAtCursor = (
    element: HTMLInputElement | HTMLTextAreaElement | null,
    textToInsert: string,
    setValue: (value: string) => void
  ) => {
    if (!element) return;

    const start = element.selectionStart || 0;
    const end = element.selectionEnd || 0;
    const currentValue = element.value;
    
    const newValue = currentValue.substring(0, start) + 
                     textToInsert + 
                     currentValue.substring(end);
    
    setValue(newValue);
    
    setTimeout(() => {
      element.focus();
      element.setSelectionRange(start + textToInsert.length, start + textToInsert.length);
    }, 0);
  };

  const formData: WidgetFormData = React.useMemo(() => ({
    id: widget?.id || "",
    name,
    universal,
    title: widgetTitle,
    description,
    cta_text: ctaText,
    cta_type: ctaType,
    image_type: imageType === "icon" ? `icon_${selectedIcon}` : imageType,
    custom_image_url: customImageUrl,
    product_ids: universal ? [] : selectedProductIds,
    available_products: availableProducts,
    image_type_options: imageTypeOptions,
    cta_type_options: ctaTypeOptions,
    icon_options: iconOptions,
    icon_color: imageType === "icon" ? iconColor : null,
  }), [name, universal, widgetTitle, description, ctaText, ctaType, imageType, selectedIcon, customImageUrl, selectedProductIds, availableProducts, imageTypeOptions, ctaTypeOptions, iconOptions, iconColor]);

  // Get preview product
  const previewProduct = React.useMemo(() => {
    if (selectedProductIds.length > 0) {
      const product = availableProducts.find(p => p.id === selectedProductIds[0]);
      if (product && product.id && product.name) {
        return { 
          id: product.id, 
          name: product.name, 
          thumbnail_url: product.thumbnail_url || "",
          sales_count: 42 
        };
      }
    }
    if (availableProducts.length > 0 && availableProducts[0] && availableProducts[0].id && availableProducts[0].name) {
      const product = availableProducts[0];
      return { 
        id: product.id, 
        name: product.name, 
        thumbnail_url: product.thumbnail_url || "",
        sales_count: 42 
      };
    }
    return null;
  }, [selectedProductIds, availableProducts]);

  const widgetData: SocialProofWidgetData = React.useMemo(() => {
    let imageUrl = null;
    if (formData.image_type === "product_thumbnail" && previewProduct?.thumbnail_url) {
      imageUrl = previewProduct.thumbnail_url;
    } else if (formData.image_type === "custom_image" && formData.custom_image_url) {
      imageUrl = formData.custom_image_url;
    }

    const defaults = {
      title: "Join 6,239 members today!",
      description: "Get lifetime access to the Small Bets Community and start your entrepreneurial journey now.",
      cta_text: "Purchase Now - $129"
    };

    const processText = (text: string, fieldType: 'title' | 'description' | 'cta_text'): string => {
      if (!text) {
        return defaults[fieldType];
      }

      if (!previewProduct) return text;

      return text
        .replace(/\{\{product_name\}\}/g, previewProduct.name)
        .replace(/\{\{sales_count\}\}/g, String(previewProduct.sales_count || 42))
        .replace(/\{\{total_customers\}\}/g, String(Math.floor((previewProduct.sales_count || 42) * 0.8)))
        .replace(/\{\{recent_buyers\}\}/g, "Sarah, Mike, and 3 others")
        .replace(/\{\{last_purchase_time\}\}/g, "2 hours ago")
        .replace(/\{\{seller_name\}\}/g, "Daniel Vassallo");
    };

    return {
      id: formData.id || "preview",
      name: formData.name,
      title: processText(formData.title, 'title'),
      description: processText(formData.description, 'description'),
      cta_text: processText(formData.cta_text, 'cta_text'),
      cta_type: formData.cta_type || 'button',
      image_url: imageUrl,
      image_type: formData.image_type,
      icon_name: formData.image_type.startsWith("icon_") ? formData.image_type.replace("icon_", "") : null,
      icon_color: formData.image_type === "icon" ? iconColor : null,
    };
  }, [formData, previewProduct, imageType, iconColor]);

  const previewCartItem: CartItem = React.useMemo(() => ({
    ...PLACEHOLDER_CART_ITEM,
    product: previewProduct ? {
      ...PLACEHOLDER_CART_ITEM.product,
      id: previewProduct.id,
      name: previewProduct.name,
      thumbnail_url: previewProduct.thumbnail_url || null,
      social_proof_widgets: [widgetData]
    } : PLACEHOLDER_CART_ITEM.product,
    quantity: 1,
    url_parameters: {},
    referrer: "",
    recommender_model_name: null,
    pay_in_installments: false,
  }), [widgetData, previewProduct]);


  const handleSubmit = async (targetStatus: "published" | "unpublished") => {
    let payload: SocialProofWidgetPayload = {
      name,
      universal,
      title: widgetTitle,
      description,
      cta_text: ctaText,
      cta_type: ctaType,
      image_type: selectedIcon ? `icon_${selectedIcon}` : imageType,
      status: targetStatus,
      product_ids: universal ? [] : selectedProductIds,
      custom_image_signed_blob_id: customImageBlobId,
      icon_color: (imageType === "icon" || imageType.startsWith("icon_")) ? iconColor : null
    };

    await onSave(payload);
  };

  // load widget data when editing
  React.useEffect(() => {
    if (widget) {
      const loadWidgetData = async () => {
        try {
          const editProps = await getSocialProofWidget(widget.id);
          setWidgetTitle(editProps.title || "");
          setDescription(editProps.description || "");
          setCtaText(editProps.cta_text || "");
          setCtaType(editProps.cta_type);
          
          // Fix the icon handling
          if (editProps.image_type?.startsWith("icon_")) {
            setImageType("icon");
            setSelectedIcon(editProps.image_type.replace("icon_", ""));
            // Load the icon color from the widget data
            setIconColor(widget.icon_color || "#000000");
          } else {
            setImageType(editProps.image_type || "product_thumbnail");
          }
          
          setSelectedProductIds(editProps.product_ids || []);
          setCustomImageUrl(editProps.custom_image_url ? editProps.custom_image_url : null);
        } catch (error) {
          console.error("Failed to load widget data:", error);
        }
      };
      void loadWidgetData();
    }
  }, [widget]);

  return (
    <div className="fixed-aside" style={{ display: "contents" }}>
      <header className="sticky-top">
        <h1>{title}</h1>
        <div className="actions">
          <Button onClick={onCancel}>
            <Icon name="x" />
            Cancel
          </Button>
          <Button color="primary" onClick={() => handleSubmit("unpublished")}>
            Save
          </Button>
          {widget?.status === "published" ? (
            <Button color="accent" onClick={() => handleSubmit("unpublished")}>
              Unpublish
            </Button>
          ) : (
            <Button color="accent" onClick={() => handleSubmit("published")}>
              Publish
            </Button>
          )}
        </div>
      </header>
      
      <main className="squished pb-10 mb-12">
        <form>
          <section>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-name`}>Widget name</label>
              </legend>
              <input
                id={`${uid}-name`}
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g., Community members"
              />
            </fieldset>

            <fieldset>
              <legend>
                <label htmlFor={`${uid}-products`}>Products</label>
              </legend>
              <Select
                inputId={`${uid}-products`}
                instanceId={`${uid}-products`}
                options={availableProducts.map(p => ({ id: p.id, label: p.name }))}
                value={selectedProductIds.map(id => {
                  const product = availableProducts.find(p => p.id === id);
                  return product ? { id: product.id, label: product.name } : null;
                }).filter((item): item is { id: string; label: string; } => item !== null)}
                onChange={(selection) => setSelectedProductIds(selection.map(s => s.id))}
                isMulti
                isClearable
                placeholder="Select products or pages to display this widget"
                isDisabled={universal}
                className="dark"
              />
              <label>
                <input
                  type="checkbox"
                  checked={universal}
                  onChange={(e) => {
                    setUniversal(e.target.checked);
                    if (e.target.checked) setSelectedProductIds([]);
                  }}
                />
                All products
              </label>
            </fieldset>

            <fieldset>
              <legend>Message</legend>
              <p>
                Click on the buttons below to quickly add them to your title, description, or call to action. 
                This will dynamically update your widget.
                <a href="#">Learn more</a>
              </p>

              <div style={{ display: "flex", flexWrap: "wrap", gap: "var(--spacer-2)", margin: "var(--spacer-3) 0" }}>
              <Button type="button" small onClick={() => handleVariableButtonClick("Country")}>Country</Button>
                <Button type="button" small onClick={() => handleVariableButtonClick("Customer")}>Customer</Button>
                <Button type="button" small onClick={() => handleVariableButtonClick("Price")}>Price</Button>
                <Button type="button" small onClick={() => handleVariableButtonClick("Product")}>Product</Button>
                <Button type="button" small onClick={() => handleVariableButtonClick("Total sales")}>Total sales</Button>
                <Button type="button" small onClick={() => handleVariableButtonClick("Recent sales")}>Recent sales</Button>
              </div>

              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-title`}>Title</label>
                </legend>
                <input
                  ref={titleInputRef}
                  id={`${uid}-title`}
                  type="text"
                  value={widgetTitle}
                  onChange={(e) => setWidgetTitle(e.target.value)}
                  onFocus={() => handleFieldFocus('title')}
                  placeholder="Join [total_sales]"
                />
              </fieldset>

              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-description`}>Description</label>
                </legend>
                <textarea
                  ref={descriptionInputRef}
                  id={`${uid}-description`}
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  onFocus={() => handleFieldFocus('description')}
                  placeholder="Get lifetime access to the [product_name] and start your entrepreneurial journey now."
                />
              </fieldset>

              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-cta-text`}>Call to action text</label>
                </legend>
                <input
                  ref={ctaTextInputRef}
                  id={`${uid}-cta-text`}
                  type="text"
                  value={ctaText}
                  onChange={(e) => setCtaText(e.target.value)}
                  onFocus={() => handleFieldFocus('cta')}
                  placeholder="Purchase Now - [price]"
                />
              </fieldset>
            </fieldset>

            <fieldset>
              <legend>
                <label htmlFor={`${uid}-cta-type`}>Call to action</label>
              </legend>
              <Select
                inputId={`${uid}-cta-type`}
                options={ctaTypeOptions.map(opt => ({ 
                  id: opt.value, 
                  label: opt.label 
                }))}
                value={ctaTypeOptions
                  .map(opt => ({ id: opt.value, label: opt.label }))
                  .find(opt => opt.id === ctaType) || null}
                onChange={(newValue) => {
                  setCtaType(newValue?.id as "button" | "link" | "none" || "none");
                }}
                isMulti={false}
                isClearable={false}
              />
            </fieldset>

            <fieldset>
              <legend>
                <label htmlFor={`${uid}-image-type`}>Image Source</label>
              </legend>
              <Select
                inputId={`${uid}-image-type`}
                options={imageTypeOptions.map(opt => ({ 
                  id: opt.value, 
                  label: opt.label 
                }))}
                value={imageTypeOptions
                  .map(opt => ({ id: opt.value, label: opt.label }))
                  .find(opt => opt.id === imageType) || null}
                onChange={(newValue) => {
                  setImageType(newValue?.id || "none");
                  // Reset icon selection when changing image type
                  if (newValue?.id !== "icon") {
                    setSelectedIcon(null);
                  }
                }}
                isMulti={false}
                isClearable={false}
              />
              
              {imageType === "custom_image" && (
                <ImageUpload
                  imageUrl={customImageUrl}
                  onImageUploaded={(signedBlobId, imageUrl) => {
                    setCustomImageBlobId(signedBlobId);
                    setCustomImageUrl(imageUrl);
                  }}
                  onImageRemoved={() => {
                    setCustomImageBlobId('');
                    setCustomImageUrl(null);
                  }}
                  disabled={false}
                />
              )}

              {imageType === "icon" && (
                <div className="space-y-4">
                  <IconSelector
                    value={selectedIcon}
                    onChange={setSelectedIcon}
                    options={iconOptions}
                    disabled={false}
                  />
                  <div>
                    <label className="block font-medium mb-2">Icon color</label>
                    <div className="relative w-10 h-10">
                      <div>
                        <div className="color-picker">
                          <input
                            type="color"
                            value={iconColor}
                            onChange={(e) => setIconColor(e.target.value)}
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              )}
            </fieldset>
          </section>
        </form>
      </main>
      
      <div className="preview-panel">
        {previewCartItem.product.social_proof_widgets && previewCartItem.product.social_proof_widgets[0] && (
          <WidgetPreview
            product={previewCartItem.product}
          />
        )}
      </div>
    </div>
  );
};

export default register({ component: SocialProofPage, propParser: createCast() });