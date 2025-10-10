import cx from "classnames";
import * as React from "react";

import {
  createUpsell,
  deleteUpsell,
  getCartItem,
  getPagedUpsells,
  getStatistics,
  pauseUpsell,
  resumeUpsell,
  updateUpsell,
  UpsellPayload,
  UpsellStatistics,
} from "$app/data/upsells";
import { Discount } from "$app/parsers/checkout";
import { ProductNativeType } from "$app/parsers/product";
import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { ProductToAdd, CartItem } from "$app/components/Checkout/cartState";
import { CheckoutPreview } from "$app/components/CheckoutDashboard/CheckoutPreview";
import { DiscountInput, InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { useClientAlert } from "$app/components/ClientAlertProvider";
import { Details } from "$app/components/Details";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { applySelection } from "$app/components/Product/ConfigurationSelector";
import { Select } from "$app/components/Select";
import { CrossSellModal, UpsellModal } from "$app/components/server-components/CheckoutPage";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";

import placeholder from "$assets/images/placeholders/upsells.png";

type Variant = {
  id: string;
  name: string;
};

export type Upsell = {
  id: string;
  name: string;
  text: string;
  description: string;
  universal: boolean;
  cross_sell: boolean;
  replace_selected_products: boolean;
  paused: boolean;
  product: {
    id: string;
    name: string;
    currency_type: CurrencyCode;
    variant: { id: string; name: string } | null;
  };
  discount: Discount | null;
  selected_products: { id: string; name: string }[];
  upsell_variants: {
    id: string;
    selected_variant: Variant;
    offered_variant: Variant;
  }[];
};

export type SortKey = "name" | "revenue" | "uses";
export type QueryParams = {
  sort: Sort<SortKey> | null;
  query: string | null;
  page: number | null;
};

const formatOfferedProductName = (productName: string, variantName?: string) =>
  `${productName}${variantName ? ` - ${variantName}` : ""}`;

export type UpsellsPageProps = {
  pages: Page[];
  upsells: Upsell[];
  products: { id: string; name: string; has_multiple_versions: boolean; native_type: ProductNativeType }[];
  pagination: PaginationProps;
};

const UpsellsPage = (props: UpsellsPageProps) => {
  const { showAlert } = useClientAlert();
  const loggedInUser = useLoggedInUser();
  const isReadOnly = !loggedInUser?.policies.upsell.create;

  const [{ upsells, pagination }, setState] = React.useState({ upsells: props.upsells, pagination: props.pagination });

  const [selectedUpsellId, setSelectedUpsellId] = React.useState<string | null>(null);
  const selectedUpsell = upsells.find(({ id }) => id === selectedUpsellId);

  const [view, setView] = React.useState<"list" | "create" | "edit">("list");

  const [isLoading, setIsLoading] = React.useState(false);

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(null);
  const thProps = useSortingTableDriver<SortKey>(sort, (newSort) => {
    loadUpsells({ page: 1, query: searchQuery, sort: newSort });
    setSort(newSort);
  });

  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);
  const loadUpsells = asyncVoid(async ({ page, query, sort }: QueryParams) => {
    try {
      activeRequest.current?.cancel();
      setIsLoading(true);

      const request = getPagedUpsells(page || 1, query, sort);
      activeRequest.current = request;

      setState(await request.response);
      setIsLoading(false);
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });
  const debouncedLoadUpsells = useDebouncedCallback(() => loadUpsells({ page: 1, query: searchQuery, sort }), 300);

  const [upsellStatistics, setUpsellStatistics] = React.useState<Record<string, UpsellStatistics>>({});
  const upsellStatisticsRequests = React.useRef<Set<string>>(new Set());

  React.useEffect(() => {
    for (const { id } of upsells) {
      if (upsellStatisticsRequests.current.has(id)) continue;
      upsellStatisticsRequests.current.add(id);
      void getStatistics(id).then(
        (statistics) => setUpsellStatistics((prev) => ({ ...prev, [id]: statistics })),
        (err: unknown) => {
          if (err instanceof AbortError) return;
          assertResponseError(err);
          showAlert(err.message, "error");
          upsellStatisticsRequests.current.delete(id);
        },
      );
    }
  }, [upsells]);

  const [searchQuery, setSearchQuery] = React.useState<string | null>(null);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  const handleCancel = () => {
    setView("list");
    setSelectedUpsellId(null);
  };

  const handleCreate = asyncVoid(async (upsellPayload: UpsellPayload) => {
    try {
      setIsLoading(true);
      setState(await createUpsell(upsellPayload));
      setView("list");
      setSelectedUpsellId(null);
      showAlert("Successfully created upsell!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  });

  const handleUpdate = asyncVoid(async (upsellPayload: UpsellPayload) => {
    if (!selectedUpsellId) return;
    try {
      setIsLoading(true);
      setState(await updateUpsell(selectedUpsellId, upsellPayload));
      setView("list");
      setSelectedUpsellId(null);
      showAlert("Successfully updated upsell!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  });

  const handleDelete = asyncVoid(async () => {
    if (!selectedUpsellId) return;
    try {
      setIsLoading(true);
      setState(await deleteUpsell(selectedUpsellId));
      setSelectedUpsellId(null);
      showAlert("Successfully deleted upsell!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  });

  const handleTogglePause = asyncVoid(async () => {
    if (!selectedUpsell) return;
    try {
      setIsLoading(true);
      if (selectedUpsell.paused) {
        await resumeUpsell(selectedUpsell.id);
        showAlert("Upsell resumed and will appear at checkout.", "success");
      } else {
        await pauseUpsell(selectedUpsell.id);
        showAlert("Upsell paused and will not appear at checkout.", "success");
      }
      const updatedData = await getPagedUpsells(pagination.page, searchQuery, sort).response;
      setState(updatedData);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  });

  return view === "list" ? (
    <Layout
      currentPage="upsells"
      pages={props.pages}
      actions={
        <>
          {upsells.length > 0 && (
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
                    debouncedLoadUpsells();
                  }}
                />
              </div>
            </Popover>
          )}
          <Button color="accent" onClick={() => setView("create")} disabled={isReadOnly}>
            New upsell
          </Button>
        </>
      }
    >
      <section className="p-4 md:p-8">
        {upsells.length > 0 ? (
          <section className="paragraphs">
            <table aria-busy={isLoading} aria-label="Upsells">
              <thead>
                <tr>
                  <th {...thProps("name")}>Upsell</th>
                  <th {...thProps("revenue")}>Revenue</th>
                  <th {...thProps("uses")}>Uses</th>
                  <th {...thProps("uses")}>Status</th>
                </tr>
              </thead>
              <tbody>
                {upsells.map((upsell) => {
                  const statistics = upsellStatistics[upsell.id];
                  return (
                    <tr
                      key={upsell.id}
                      onClick={() => setSelectedUpsellId(upsell.id)}
                      aria-selected={selectedUpsellId === upsell.id}
                    >
                      <td>
                        <div>
                          <div>
                            <b>{upsell.name}</b>
                          </div>
                          <small>{formatOfferedProductName(upsell.product.name, upsell.product.variant?.name)}</small>
                        </div>
                      </td>
                      {statistics ? (
                        <>
                          <td>
                            {formatPriceCentsWithCurrencySymbol(
                              upsell.product.currency_type,
                              statistics.revenue_cents,
                              {
                                symbolFormat: "short",
                              },
                            )}
                          </td>
                          <td>{statistics.uses.total}</td>
                        </>
                      ) : (
                        <>
                          <td aria-busy></td>
                          <td aria-busy> </td>
                        </>
                      )}
                      <td>{upsell.paused ? "Paused" : "Live"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {pagination.pages > 1 ? (
              <Pagination
                onChangePage={(newPage) => loadUpsells({ page: newPage, query: searchQuery, sort })}
                pagination={pagination}
              />
            ) : null}
          </section>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Offering an upsell at checkout</h2>
            Upsells allow you to suggest additional products to your customer at checkout. You can nudge them to
            purchase either an upgraded version or an extra product add-on.
            <Button color="accent" onClick={() => setView("create")}>
              New upsell
            </Button>
            <a href="/help/article/331-creating-upsells" target="_blank" rel="noreferrer">
              Learn more about upsells
            </a>
          </div>
        )}
        {selectedUpsell ? (
          <UpsellDrawer
            selectedUpsell={selectedUpsell}
            statistics={upsellStatistics[selectedUpsell.id] ?? null}
            onCreate={() => setView("create")}
            onEdit={() => setView("edit")}
            onDelete={handleDelete}
            onTogglePause={handleTogglePause}
            onClose={handleCancel}
            isLoading={isLoading}
          />
        ) : null}
      </section>
    </Layout>
  ) : view === "create" ? (
    <Form
      title="Create an upsell"
      products={props.products}
      upsell={selectedUpsell ? { ...selectedUpsell, name: `${selectedUpsell.name} (copy)` } : undefined}
      onCancel={handleCancel}
      onSave={handleCreate}
      isLoading={isLoading}
    />
  ) : (
    <Form
      title="Edit upsell"
      products={props.products}
      onCancel={handleCancel}
      upsell={selectedUpsell}
      onSave={handleUpdate}
      isLoading={isLoading}
    />
  );
};

const UpsellDrawer = ({
  selectedUpsell,
  statistics,
  onCreate,
  onEdit,
  onDelete,
  onTogglePause,
  onClose,
  isLoading,
}: {
  selectedUpsell: Upsell;
  statistics: UpsellStatistics | null;
  onCreate: () => void;
  onEdit: () => void;
  onDelete: () => void;
  onTogglePause: () => void;
  onClose: () => void;
  isLoading: boolean;
}) => {
  const loggedInUser = useLoggedInUser();
  const isReadOnly = !loggedInUser?.policies.upsell.create;
  return (
    <aside>
      <header>
        <h2>{selectedUpsell.name}</h2>
        <button className="close" aria-label="Close" onClick={onClose} />
      </header>
      <section className="stack">
        <h3>Details</h3>
        <div>
          <h5>Offer text</h5>
          {selectedUpsell.text}
        </div>
        {selectedUpsell.discount ? (
          <div>
            <h5>Discount</h5>
            {selectedUpsell.discount.type === "percent"
              ? `${selectedUpsell.discount.percents}%`
              : formatPriceCentsWithCurrencySymbol(
                  selectedUpsell.product.currency_type,
                  selectedUpsell.discount.cents,
                  {
                    symbolFormat: "long",
                  },
                )}
          </div>
        ) : null}
        {statistics ? (
          <>
            <div>
              <h5>Uses</h5>
              {statistics.uses.total}
            </div>
            <div>
              <h5>Revenue</h5>
              {formatPriceCentsWithCurrencySymbol(selectedUpsell.product.currency_type, statistics.revenue_cents, {
                symbolFormat: "short",
              })}
            </div>
          </>
        ) : null}
        <div>
          <h5>Status</h5>
          <span>{selectedUpsell.paused ? "Paused" : "Live"}</span>
        </div>
      </section>
      <section className="override grid auto-cols-fr grid-flow-col gap-4">
        <Button onClick={onTogglePause} disabled={isLoading || isReadOnly}>
          {selectedUpsell.paused ? "Resume upsell" : "Pause upsell"}
        </Button>
      </section>
      {selectedUpsell.cross_sell ? (
        <section className="stack">
          <h3>Selected products</h3>
          {selectedUpsell.universal ? (
            <div>
              <h5>All products</h5>
            </div>
          ) : (
            selectedUpsell.selected_products.map(({ id, name }) => (
              <div key={id}>
                <div>
                  <h5>{name}</h5>
                  {statistics
                    ? `${statistics.uses.selected_products[id] ?? 0} ${(statistics.uses.selected_products[id] ?? 0) === 1 ? "use" : "uses"} from this product`
                    : null}
                </div>
              </div>
            ))
          )}
        </section>
      ) : (
        <section className="stack">
          <h3>Selected product</h3>
          <div>
            <h5>{selectedUpsell.product.name}</h5>
          </div>
        </section>
      )}
      {selectedUpsell.cross_sell ? (
        <section className="stack">
          <h3>Offered product</h3>
          <div>
            <h5>{formatOfferedProductName(selectedUpsell.product.name, selectedUpsell.product.variant?.name)}</h5>
          </div>
        </section>
      ) : (
        <section className="stack">
          <h3>Offers</h3>
          {selectedUpsell.upsell_variants.map((upsellVariant) => (
            <div key={upsellVariant.id}>
              <div>
                <h5>{`${upsellVariant.selected_variant.name} → ${upsellVariant.offered_variant.name}`}</h5>
                {statistics
                  ? `${statistics.uses.upsell_variants[upsellVariant.id] ?? 0} ${(statistics.uses.upsell_variants[upsellVariant.id] ?? 0) === 1 ? "use" : "uses"}`
                  : null}
              </div>
            </div>
          ))}
        </section>
      )}
      <section className="override grid auto-cols-fr grid-flow-row gap-4 sm:grid-flow-col">
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

const Form = ({
  title,
  upsell,
  onSave,
  products,
  onCancel,
  isLoading,
}: {
  title: string;
  upsell?: Upsell | undefined;
  onSave: (upsell: UpsellPayload) => void;
  products: { id: string; name: string; has_multiple_versions: boolean; native_type: ProductNativeType }[];
  onCancel: () => void;
  isLoading: boolean;
}) => {
  const uid = React.useId();
  const { showAlert } = useClientAlert();
  const [name, setName] = React.useState<{ value: string; error?: boolean }>({ value: upsell?.name ?? "" });
  const [offerText, setOfferText] = React.useState<{ value: string; error?: boolean }>({ value: upsell?.text ?? "" });
  const [offerDescription, setOfferDescription] = React.useState(upsell?.description ?? "");
  const [paused, setPaused] = React.useState(upsell?.paused ?? false);

  const [cartItems, setCartItems] = React.useState<Record<string, ProductToAdd>>({});

  const [type, setType] = React.useState(
    upsell
      ? upsell.cross_sell
        ? upsell.replace_selected_products
          ? "replacement-cross-sell"
          : "cross-sell"
        : "upsell"
      : "cross-sell",
  );
  const isCrossSell = type === "cross-sell" || type === "replacement-cross-sell";

  const [discount, setDiscount] = React.useState<null | InputtedDiscount>(
    upsell?.discount
      ? upsell.discount.type === "percent"
        ? { type: "percent", value: upsell.discount.percents }
        : { type: "cents", value: upsell.discount.cents }
      : null,
  );

  const [selectedProductId, setSelectedProductId] = React.useState<{ value: null | string; error?: boolean }>({
    value: upsell && !upsell.cross_sell ? upsell.product.id : null,
  });
  const selectedOption = products.find(({ id }) => id === selectedProductId.value);
  const selectedCartItem = selectedProductId.value ? cartItems[selectedProductId.value] : null;
  const selectedProduct = selectedCartItem?.product;
  const [universal, setUniversal] = React.useState(upsell?.universal ?? false);
  React.useEffect(
    () => setSelectedProductIds((selectedProductIds) => ({ ...selectedProductIds, error: false })),
    [universal],
  );

  const [variants, setVariants] = React.useState<{ selectedVariantId: string; offeredVariantId: string }[]>(
    upsell?.upsell_variants.map(({ selected_variant, offered_variant }) => ({
      selectedVariantId: selected_variant.id,
      offeredVariantId: offered_variant.id,
    })) ?? [],
  );
  const setVariant = (selectedVariantId: string, offeredVariantId: string | null) =>
    setVariants((prevVariants) => {
      const newVariants = prevVariants.filter((variant) => variant.selectedVariantId !== selectedVariantId);
      return offeredVariantId ? [...newVariants, { selectedVariantId, offeredVariantId }] : newVariants;
    });

  const [selectedProductIds, setSelectedProductIds] = React.useState<{ value: string[]; error?: boolean }>({
    value: upsell?.cross_sell ? upsell.selected_products.map(({ id }) => id) : [],
  });
  const selectedOptions = products.filter(({ id }) => selectedProductIds.value.includes(id));
  const selectedProducts = selectedProductIds.value.flatMap((id) => cartItems[id] ?? []);

  const [offeredProductId, setOfferedProductId] = React.useState<{ value: null | string; error?: boolean }>({
    value: upsell?.cross_sell ? upsell.product.id : null,
  });
  const offeredOption = products.find(({ id }) => id === offeredProductId.value);
  const offeredCartItem = offeredProductId.value ? cartItems[offeredProductId.value] : null;
  const offeredProduct = offeredCartItem?.product;
  const offerableProducts = products.filter(
    ({ id, native_type }) => id !== offeredProductId.value && native_type !== "call",
  );

  const [offeredVariantId, setOfferedVariantId] = React.useState<{ value: null | string; error?: boolean }>({
    value: upsell?.cross_sell ? (upsell.product.variant?.id ?? null) : null,
  });
  const offeredVariant = offeredProduct?.options.find(({ id }) => id === offeredVariantId.value);

  const handleSubmit = () => {
    if (
      name.value === "" ||
      offerText.value === "" ||
      (discount && discount.value === null) ||
      (isCrossSell &&
        ((!universal && selectedProductIds.value.length === 0) ||
          !offeredProduct ||
          (offeredProduct.options.length > 0 && offeredVariantId.value === null))) ||
      (!isCrossSell && selectedProductId.value === null)
    ) {
      setName((name) => ({ ...name, error: name.value === "" }));
      setOfferText((offerText) => ({ ...offerText, error: offerText.value === "" }));

      if (isCrossSell) {
        if (!universal)
          setSelectedProductIds((selectedProductIds) => ({
            ...selectedProductIds,
            error: selectedProductIds.value.length === 0,
          }));
        setOfferedProductId((offeredProductId) => ({ ...offeredProductId, error: offeredProductId.value === null }));
        if (offeredProduct && offeredProduct.options.length > 0)
          setOfferedVariantId((offeredVariantId) => ({ ...offeredVariantId, error: offeredVariantId.value === null }));
      } else {
        setSelectedProductId((selectedProductId) => ({
          ...selectedProductId,
          error: selectedProductId.value === null,
        }));
      }

      if (discount) setDiscount({ ...discount, error: discount.value === null });
      showAlert("Please complete all required fields.", "error");
      return;
    }

    onSave({
      name: name.value,
      text: offerText.value,
      description: offerDescription,
      isCrossSell,
      replaceSelectedProducts: type === "replacement-cross-sell",
      universal,
      productId: (isCrossSell ? offeredProductId.value : selectedProductId.value) ?? "",
      variantId: isCrossSell ? offeredVariantId.value : null,
      offerCode:
        isCrossSell && discount?.value
          ? discount.type === "cents"
            ? { amount_cents: discount.value }
            : { amount_percentage: discount.value }
          : null,
      productIds: isCrossSell ? selectedProductIds.value : [],
      upsellVariants: !isCrossSell ? variants : [],
      paused,
    });
  };

  const previewCartItem: CartItem = {
    ...((isCrossSell ? selectedProducts[0] : selectedCartItem) ?? PLACEHOLDER_CART_ITEM),
    quantity: 1,
    url_parameters: {},
    referrer: "",
    recommender_model_name: null,
    pay_in_installments: false,
  };

  const useLoadCartItem = (productId: string | null) => {
    React.useEffect(() => {
      if (!productId || cartItems[productId]) return;
      void getCartItem(productId).then(
        (cartItem) => setCartItems((prev) => ({ ...prev, [productId]: cartItem })),
        (e: unknown) => {
          assertResponseError(e);
          showAlert(e.message, "error");
        },
      );
    }, [productId]);
  };
  useLoadCartItem(selectedProductId.value);
  useLoadCartItem(offeredProductId.value);
  useLoadCartItem(selectedProductIds.value[0] ?? null);

  const handlePausedChange = (evt: React.ChangeEvent<HTMLInputElement>) => setPaused(evt.target.value === "true");

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={title}
        actions={
          <>
            <Button onClick={onCancel} disabled={isLoading}>
              <Icon name="x-square" />
              Cancel
            </Button>
            <Button type="submit" color="accent" onClick={handleSubmit} disabled={isLoading}>
              {isLoading ? "Saving..." : "Save"}
            </Button>
          </>
        }
      />
      <div className="squished fixed-aside flex-1 lg:grid lg:grid-cols-[1fr_30vw]">
        <form>
          <section className="p-8!">
            <p>
              When a customer clicks "Pay", offer a version upgrade or another product with or without a discount.{" "}
              <a href="/help/article/331-creating-upsells" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </p>
            <fieldset className={cx({ danger: name.error })}>
              <legend>
                <label htmlFor={`${uid}name`}>Name</label>
              </legend>
              <input
                type="text"
                id={`${uid}name`}
                placeholder="Complete course upsell"
                value={name.value}
                onChange={(evt) => setName({ value: evt.target.value })}
                aria-invalid={name.error}
              />
            </fieldset>
            <fieldset className={cx({ danger: offerText.error })}>
              <legend>
                <label htmlFor={`${uid}offerText`}>Offer text</label>
              </legend>
              <input
                type="text"
                id={`${uid}offerText`}
                placeholder="Enhance your learning experience"
                value={offerText.value}
                onChange={(evt) => setOfferText({ value: evt.target.value })}
                aria-invalid={offerText.error}
              />
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}offerDescription`}>Offer description</label>
              </legend>
              <textarea
                id={`${uid}offerDescription`}
                placeholder="You'll enjoy a range of exclusive features, including..."
                value={offerDescription}
                onChange={(evt) => setOfferDescription(evt.target.value)}
              />
            </fieldset>
            <fieldset>
              <legend>Status</legend>
              <label>
                <input type="radio" name="paused" value="false" checked={!paused} onChange={handlePausedChange} />
                Live
              </label>
              <label>
                <input type="radio" name="paused" value="true" checked={paused} onChange={handlePausedChange} />
                Paused
              </label>
              <small>Paused upsells will not appear at checkout. You can resume anytime.</small>
            </fieldset>
            <fieldset>
              <legend>Type of offer</legend>
              <label>
                <input
                  type="radio"
                  checked={type === "cross-sell"}
                  onChange={(evt) => {
                    if (evt.target.checked) setType("cross-sell");
                  }}
                />
                Add another product to the cart
              </label>
              <label>
                <input
                  type="radio"
                  checked={type === "replacement-cross-sell"}
                  onChange={(evt) => {
                    if (evt.target.checked) setType("replacement-cross-sell");
                  }}
                />
                Replace the selected products with another product
              </label>
              <label>
                <input
                  type="radio"
                  checked={type === "upsell"}
                  onChange={(evt) => {
                    if (evt.target.checked) setType("upsell");
                  }}
                />
                Replace the version selected with another version of the same product
              </label>
            </fieldset>
            {isCrossSell ? (
              <>
                <fieldset className={cx({ danger: selectedProductIds.error })}>
                  <legend>
                    <label htmlFor={`${uid}selectedProducts`}>Apply to these products</label>
                  </legend>
                  <Select
                    inputId={`${uid}selectedProducts`}
                    instanceId={`${uid}selectedProducts`}
                    options={products
                      .filter(({ id }) => id !== offeredProductId.value)
                      .map(({ id, name: label }) => ({ id, label }))}
                    value={selectedOptions.map(({ id, name }) => ({ id, label: name }))}
                    onChange={(selectedOptions) =>
                      setSelectedProductIds({ value: selectedOptions.map(({ id }) => id) })
                    }
                    isDisabled={universal}
                    isMulti
                    isClearable
                    aria-invalid={selectedProductIds.error}
                  />
                  <label>
                    <input type="checkbox" checked={universal} onChange={(evt) => setUniversal(evt.target.checked)} />
                    All products
                  </label>
                </fieldset>
                <fieldset className={cx({ danger: offeredProductId.error })}>
                  <legend>
                    <label htmlFor={`${uid}offeredProduct`}>Product to offer</label>
                  </legend>
                  <Select
                    inputId={`${uid}offeredProduct`}
                    instanceId={`${uid}offeredProduct`}
                    options={offerableProducts.map(({ id, name: label }) => ({ id, label }))}
                    value={offeredOption ? { id: offeredOption.id, label: offeredOption.name } : null}
                    onChange={(selectedOption) => {
                      if (selectedOption?.id !== offeredProductId.value) setOfferedVariantId({ value: null });
                      setOfferedProductId({ value: selectedOption?.id ?? null });
                    }}
                    isMulti={false}
                    isClearable
                    aria-invalid={offeredProductId.error}
                  />
                </fieldset>
                {offeredProduct && offeredProduct.options.length > 0 ? (
                  <fieldset className={cx({ danger: offeredVariantId.error })}>
                    <legend>
                      <label htmlFor={`${uid}offeredVariant`}>Version to offer</label>
                    </legend>
                    <Select
                      inputId={`${uid}offeredVariant`}
                      instanceId={`${uid}offeredVariant`}
                      options={offeredProduct.options.map(({ id, name }) => ({ label: name, id }))}
                      value={offeredVariant ? { id: offeredVariant.id, label: offeredVariant.name } : null}
                      onChange={(selectedOption) => setOfferedVariantId({ value: selectedOption?.id ?? null })}
                      isMulti={false}
                      isClearable
                      aria-invalid={offeredVariantId.error}
                    />
                  </fieldset>
                ) : null}
                <fieldset>
                  <legend>Settings</legend>
                  <Details
                    className="toggle"
                    open={!!discount}
                    summary={
                      <label>
                        <input
                          type="checkbox"
                          role="switch"
                          checked={!!discount}
                          onChange={(evt) => setDiscount(evt.target.checked ? { type: "percent", value: 0 } : null)}
                        />
                        Add discount to the offered product
                      </label>
                    }
                  >
                    {discount ? (
                      <div className="dropdown">
                        <DiscountInput discount={discount} setDiscount={setDiscount} currencyCode="usd" />
                      </div>
                    ) : null}
                  </Details>
                </fieldset>
              </>
            ) : (
              <>
                <fieldset className={cx({ danger: selectedProductId.error })}>
                  <legend>
                    <label htmlFor={`${uid}selectedProduct`}>Apply to this product</label>
                  </legend>
                  <Select
                    inputId={`${uid}selectedProduct`}
                    instanceId={`${uid}selectedProduct`}
                    options={products
                      .filter(({ has_multiple_versions }) => has_multiple_versions)
                      .map(({ id, name: label }) => ({ id, label }))}
                    value={selectedOption ? { label: selectedOption.name, id: selectedOption.id } : null}
                    onChange={(newOption) => {
                      if (newOption?.id !== selectedProductId.value) setVariants([]);
                      setSelectedProductId({ value: newOption?.id ?? null });
                    }}
                    isMulti={false}
                    isClearable
                    aria-invalid={selectedProductId.error}
                  />
                </fieldset>
                {selectedProduct ? (
                  <div className="override grid grid-cols-[1fr_auto_1fr] gap-2" aria-label="Upsell versions">
                    <b>Version selected</b>
                    <div />
                    <b>Version to offer</b>
                    {selectedProduct.options.map((option) => {
                      const selectedOption = selectedProduct.options.find(
                        ({ id }) =>
                          id ===
                          variants.find(({ selectedVariantId }) => option.id === selectedVariantId)?.offeredVariantId,
                      );
                      return (
                        <React.Fragment key={option.id}>
                          <div className="input read-only">{option.name}</div>
                          <Icon name="arrow-right-circle" />
                          <Select
                            options={selectedProduct.options.flatMap(({ id, name: label }) =>
                              id !== option.id ? { id, label } : [],
                            )}
                            onChange={(newOption) => setVariant(option.id, newOption?.id ?? null)}
                            value={selectedOption ? { label: selectedOption.name, id: selectedOption.id } : null}
                            aria-label={`Version to offer for ${option.name}`}
                            isMulti={false}
                            isClearable
                          />
                        </React.Fragment>
                      );
                    })}
                  </div>
                ) : null}
              </>
            )}
          </section>
        </form>
        <CheckoutPreview cartItem={previewCartItem}>
          <dialog open aria-labelledby={`${uid}preview`}>
            <header>
              <h2 id={`${uid}preview`}>{offerText.value}</h2>
              <button className="close" />
            </header>
            {isCrossSell ? (
              <CrossSellModal
                crossSell={{
                  id: "",
                  replace_selected_products: type === "replacement-cross-sell",
                  text: offerText.value,
                  description: offerDescription,
                  offered_product: {
                    ...(offeredCartItem ?? PLACEHOLDER_CART_ITEM),
                    option_id: offeredVariantId.value ?? previewCartItem.option_id,
                    price: offeredCartItem
                      ? applySelection(offeredCartItem.product, null, {
                          rent: !!offeredCartItem.product.rental?.rent_only,
                          optionId: offeredVariantId.value,
                          price: { error: false, value: null },
                          quantity: 1,
                          recurrence: offeredCartItem.recurrence,
                          callStartTime: null,
                          payInInstallments: false,
                        }).priceCents
                      : 0,
                    accepted_offer: null,
                  },
                  discount: discount?.value
                    ? {
                        ...(discount.type === "percent"
                          ? { type: "percent", percents: discount.value }
                          : { type: "fixed", cents: discount.value }),
                        product_ids: null,
                        minimum_quantity: null,
                        expires_at: null,
                        duration_in_billing_cycles: null,
                        minimum_amount_cents: null,
                      }
                    : null,
                  ratings: null,
                }}
                accept={() => {}}
                decline={() => {}}
                cart={{
                  items: [previewCartItem],
                  discountCodes: [],
                }}
              />
            ) : (
              <UpsellModal
                upsell={{
                  id: "",
                  text: offerText.value,
                  description: offerDescription,
                  offeredOption: selectedProduct?.options.find(({ id }) =>
                    variants.some(({ offeredVariantId }) => offeredVariantId === id),
                  ) ?? {
                    id: "",
                    name: "",
                    quantity_left: null,
                    description: "",
                    price_difference_cents: 0,
                    recurrence_price_values: null,
                    is_pwyw: false,
                    duration_in_minutes: null,
                  },
                  item: previewCartItem,
                }}
                cart={{
                  items: [previewCartItem],
                  discountCodes: [],
                }}
                accept={() => {}}
                decline={() => {}}
              />
            )}
          </dialog>
        </CheckoutPreview>
      </div>
    </>
  );
};

export default UpsellsPage;
