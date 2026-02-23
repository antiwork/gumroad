import { router, usePage } from "@inertiajs/react";
import { produce } from "immer";
import * as React from "react";
import { cast, is } from "ts-safe-cast";

import { deletePurchasedProduct, setPurchaseArchived } from "$app/data/library";
import { ProductNativeType } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { writeQueryParams } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { CardContent, Card as UICard } from "$app/components/ui/Card";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { ProductCard, ProductCardFigure, ProductCardFooter, ProductCardHeader } from "$app/components/ui/ProductCard";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { StretchedLink } from "$app/components/ui/StretchedLink";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

import placeholder from "$assets/images/placeholders/library.png";

export type Result = {
  product: {
    name: string;
    creator_id: string;
    creator: { name: string; profile_url: string; avatar_url: string | null } | null;
    thumbnail_url: string | null;
    updated_at: string;
    native_type: ProductNativeType;
    permalink: string;
    has_third_party_analytics: boolean;
  };
  purchase: {
    id: string;
    email: string;
    is_archived: boolean;
    download_url: string | null;
    variants: string | null;
    bundle_id: string | null;
    is_bundle_purchase: boolean;
  };
};

export const Card = ({
  result,
  onArchive,
  onDelete,
}: {
  result: Result;
  onArchive: () => void;
  onDelete: (confirm?: boolean) => void;
}) => {
  const { product, purchase } = result;
  const [isPopoverOpen, setIsPopoverOpen] = React.useState(false);

  const toggleArchived = asyncVoid(async () => {
    const data = { purchase_id: result.purchase.id, is_archived: !result.purchase.is_archived };
    try {
      await setPurchaseArchived(data);
      onArchive();
      showAlert(result.purchase.is_archived ? "Product unarchived!" : "Product archived!", "success");
      setIsPopoverOpen(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  const name = purchase.variants ? `${product.name} - ${purchase.variants}` : product.name;

  return (
    <ProductCard>
      <ProductCardFigure>
        <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
      </ProductCardFigure>
      <ProductCardHeader>
        {purchase.download_url ? (
          <StretchedLink href={purchase.download_url} aria-label={name}>
            <h3 itemProp="name">{name}</h3>
          </StretchedLink>
        ) : (
          <h3 itemProp="name">{name}</h3>
        )}
      </ProductCardHeader>
      <ProductCardFooter>
        <div className="flex-1 p-4">
          {product.creator ? (
            <AuthorByline
              name={product.creator.name}
              profileUrl={product.creator.profile_url}
              avatarUrl={product.creator.avatar_url ?? undefined}
            />
          ) : null}
        </div>
        <div className="p-4">
          <Popover open={isPopoverOpen} onOpenChange={setIsPopoverOpen}>
            <PopoverTrigger aria-label="Open product action menu">
              <Icon name="three-dots" />
            </PopoverTrigger>
            <PopoverContent className="border-0 p-0 shadow-none" usePortal>
              <div role="menu">
                <div role="menuitem" onClick={toggleArchived}>
                  <Icon name="archive" />
                  &ensp;{purchase.is_archived ? "Unarchive" : "Archive"}
                </div>
                <div className="danger" role="menuitem" onClick={() => onDelete()}>
                  <Icon name="trash2" />
                  &ensp;Delete permanently
                </div>
              </div>
            </PopoverContent>
          </Popover>
        </div>
      </ProductCardFooter>
    </ProductCard>
  );
};

export const DeleteProductModal = ({
  deleting,
  onCancel,
  onDelete,
}: {
  deleting: Result | null;
  onCancel: () => void;
  onDelete: (deleted: Result) => void;
}) => {
  const deletePurchase = asyncVoid(async (result: Result) => {
    try {
      await deletePurchasedProduct({ purchase_id: result.purchase.id });
      onDelete(result);
      showAlert("Product deleted!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  return (
    <Modal
      open={!!deleting}
      onClose={onCancel}
      title="Delete Product"
      footer={
        <>
          <Button onClick={onCancel}>Cancel</Button>
          <Button color="danger" onClick={() => deletePurchase(assertDefined(deleting, "Invalid state"))}>
            Confirm
          </Button>
        </>
      }
    >
      <h4>Are you sure you want to delete {deleting?.product.name ?? ""}?</h4>
    </Modal>
  );
};

type Props = {
  results: Result[];
  creators: { id: string; name: string }[];
  bundles: { id: string; label: string }[];
  reviews_page_enabled: boolean;
  following_wishlists_enabled: boolean;
};

type Params = {
  sort: "recently_updated" | "purchase_date";
  query: string;
  creators: string[];
  showArchivedOnly: boolean;
  bundles: string[];
};

type State = {
  results: Result[];
  search: Params;
};

type Action =
  | { type: "set-search"; search: Partial<Params> }
  | { type: "update-search"; search: Partial<Params> }
  | { type: "set-archived"; purchaseId: string; isArchived: boolean }
  | { type: "delete-purchase"; id: string };

const reducer: React.Reducer<State, Action> = produce((state, action) => {
  switch (action.type) {
    case "set-search":
      state.search = { ...state.search, ...action.search };
      break;
    case "update-search":
      state.search = { ...state.search, ...action.search };
      updateUrl(state.search);
      break;
    case "set-archived": {
      const result = state.results.find((result) => result.purchase.id === action.purchaseId);
      if (result) result.purchase.is_archived = action.isArchived;
      if (!state.results.some((result) => result.purchase.is_archived && state.search.showArchivedOnly))
        state.search.showArchivedOnly = false;
      updateUrl(state.search);
      break;
    }
    case "delete-purchase": {
      const index = state.results.findIndex((result) => result.purchase.id === action.id);
      if (index !== -1) state.results.splice(index, 1);
      break;
    }
  }
});

const updateUrl = (search: Partial<Params>) => {
  const currentUrl = new URL(window.location.href);
  const newParams = {
    sort: search.sort || null,
    query: search.query || null,
    creators: search.creators?.join(",") || null,
    bundles: search.bundles?.join(",") || null,
    show_archived_only: search.showArchivedOnly ? "true" : null,
  };
  const newUrl = writeQueryParams(currentUrl, newParams);
  if (newUrl.toString() !== window.location.href)
    window.history.pushState(newParams, document.title, newUrl.toString());
};

const extractParams = (rawParams: URLSearchParams): Params => ({
  sort: rawParams.get("sort") === "purchase_date" ? "purchase_date" : "recently_updated",
  query: rawParams.get("query") ?? "",
  creators: rawParams.get("creators")?.split(",") ?? [],
  bundles: rawParams.get("bundles")?.split(",") ?? [],
  showArchivedOnly: rawParams.get("show_archived_only") === "true",
});

export default function LibraryPage() {
  const { results, creators, bundles, reviews_page_enabled, following_wishlists_enabled } = cast<Props>(
    usePage().props,
  );

  const originalLocation = useOriginalLocation();
  const discoverUrl = useDiscoverUrl();
  const [state, dispatch] = React.useReducer(reducer, null, () => ({
    search: extractParams(new URL(originalLocation).searchParams),
    results,
  }));
  const [enteredQuery, setEnteredQuery] = React.useState(state.search.query);
  useGlobalEventListener("popstate", (e: PopStateEvent) => {
    const search = is<Params>(e.state) ? e.state : extractParams(new URLSearchParams(window.location.search));
    dispatch({ type: "set-search", search });
    setEnteredQuery(search.query);
  });
  const filteredResults = React.useMemo(() => {
    const filtered = state.results.filter(
      (result) =>
        !result.purchase.is_bundle_purchase &&
        result.purchase.is_archived === state.search.showArchivedOnly &&
        (state.search.creators.length === 0 || state.search.creators.includes(result.product.creator_id)) &&
        (state.search.bundles.length === 0 ||
          (result.purchase.bundle_id && state.search.bundles.includes(result.purchase.bundle_id))) &&
        (!state.search.query || result.product.name.toLowerCase().includes(state.search.query.toLowerCase())),
    );
    if (state.search.sort !== "purchase_date")
      filtered.sort((a, b) => b.product.updated_at.localeCompare(a.product.updated_at));
    return filtered;
  }, [state.results, state.search]);

  const creatorsWithProductCounts = React.useMemo(() => {
    const productCountByCreatorId = state.results.reduce((counts, result) => {
      if (result.purchase.is_archived === state.search.showArchivedOnly && !result.purchase.is_bundle_purchase) {
        const creatorId = result.product.creator_id;
        counts.set(creatorId, (counts.get(creatorId) ?? 0) + 1);
      }
      return counts;
    }, new Map<string, number>());

    return creators
      .map((creator) => ({
        ...creator,
        count: productCountByCreatorId.get(creator.id) ?? 0,
      }))
      .filter((creator) => creator.count > 0)
      .sort((a, b) => b.count - a.count);
  }, [creators, state.results, state.search.showArchivedOnly]);

  const [resultsLimit, setResultsLimit] = React.useState(15);
  React.useEffect(() => setResultsLimit(15), [filteredResults]);

  const isDesktop = useIsAboveBreakpoint("lg");
  const [mobileFiltersExpanded, setMobileFiltersExpanded] = React.useState(false);
  const [showingAllCreators, setShowingAllCreators] = React.useState(false);
  const archivedCount = state.results.filter((result) => result.purchase.is_archived).length;
  const showArchivedNotice =
    !state.search.showArchivedOnly && !state.results.some((result) => !result.purchase.is_archived);
  const hasParams =
    state.search.showArchivedOnly || state.search.query || state.search.creators.length || state.search.bundles.length;
  const [deleting, setDeleting] = React.useState<Result | null>(null);

  const sortUid = React.useId();
  const bundlesUid = React.useId();

  const deletePurchase = asyncVoid(async (result: Result) => {
    try {
      await deletePurchasedProduct({ purchase_id: result.purchase.id });
      dispatch({ type: "delete-purchase", id: result.purchase.id });
      showAlert("Product deleted!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  const url = new URL(useOriginalLocation());
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();
  useRunOnce(() => {
    const purchaseIds = url.searchParams.getAll("purchase_id");
    if (purchaseIds.length === 0) return;

    url.searchParams.delete("purchase_id");
    router.replace({ url: url.pathname + url.search, preserveState: true, preserveScroll: true });

    const email = results.find(({ purchase }) => purchase.id === purchaseIds[0])?.purchase.email;
    if (email) showAlert(`Your purchase was successful! We sent a receipt to ${email}.`, "success");

    for (const purchaseId of purchaseIds) {
      const product = results.find(({ purchase }) => purchase.id === purchaseId)?.product;
      if (!product) continue;

      if (product.has_third_party_analytics)
        addThirdPartyAnalytics({
          permalink: product.permalink,
          location: "receipt",
          purchaseId,
        });
    }
  });

  const handleSearchChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setEnteredQuery(e.target.value);
    dispatch({ type: "set-search", search: { query: e.target.value } });
  };

  const handleSearchBlur = () => {
    dispatch({ type: "update-search", search: { query: enteredQuery } });
  };

  const handleSearchKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") dispatch({ type: "update-search", search: { query: enteredQuery } });
  };

  const shouldShowFilter = !showArchivedNotice && (hasParams || archivedCount > 0 || state.results.length > 9);

  return (
    <Layout
      selectedTab="purchases"
      onScrollToBottom={() => setResultsLimit((prevNumberOfResults) => prevNumberOfResults + 15)}
      reviewsPageEnabled={reviews_page_enabled}
      followingWishlistsEnabled={following_wishlists_enabled}
    >
      <section className="space-y-4 p-4 md:p-8">
        {state.results.length === 0 || showArchivedNotice ? (
          <Placeholder>
            {state.results.length === 0 ? (
              <>
                <PlaceholderImage src={placeholder} />
                <h2 className="library-header">You haven't bought anything... yet!</h2>
                Once you do, it'll show up here so you can download, watch, read, or listen to all your purchases.
                <Button asChild color="accent">
                  <a href={discoverUrl}>Discover products</a>
                </Button>
              </>
            ) : (
              <>
                <h2 className="library-header">You've archived all your products.</h2>
                <Button
                  color="accent"
                  onClick={(e) => {
                    e.preventDefault();
                    dispatch({ type: "update-search", search: { showArchivedOnly: true } });
                  }}
                >
                  See archive
                </Button>
              </>
            )}
          </Placeholder>
        ) : null}
        {archivedCount > 0 && !state.search.showArchivedOnly && !showArchivedNotice ? (
          <Alert role="status" variant="info" className="mb-5">
            You have {archivedCount} archived purchase{archivedCount === 1 ? "" : "s"}.{" "}
            <button
              type="button"
              className="cursor-pointer underline all-unset"
              onClick={() => dispatch({ type: "update-search", search: { showArchivedOnly: true } })}
            >
              Click here to view
            </button>
          </Alert>
        ) : null}
        <div
          className={classNames(
            "grid grid-cols-1 items-start gap-x-16 gap-y-8",
            shouldShowFilter && "lg:grid-cols-[var(--grid-cols-sidebar)]",
          )}
        >
          {shouldShowFilter ? (
            <UICard className="overflow-y-auto lg:sticky lg:inset-y-4 lg:max-h-[calc(100vh-2rem)]" aria-label="Filters">
              <CardContent asChild>
                <header>
                  <div className="grow">
                    {filteredResults.length
                      ? `Showing 1-${Math.min(filteredResults.length, resultsLimit)} of ${filteredResults.length} products`
                      : "No products found"}
                  </div>
                  {isDesktop ? null : (
                    <button
                      className="cursor-pointer underline all-unset"
                      onClick={() => setMobileFiltersExpanded(!mobileFiltersExpanded)}
                    >
                      Filter
                    </button>
                  )}
                </header>
              </CardContent>
              {isDesktop || mobileFiltersExpanded ? (
                <>
                  <CardContent>
                    <div className="input input-wrapper product-search__wrapper grow">
                      <Icon name="solid-search" />
                      <input
                        className="search-products"
                        placeholder="Search products"
                        value={enteredQuery}
                        onChange={handleSearchChange}
                        onBlur={handleSearchBlur}
                        onKeyDown={handleSearchKeyDown}
                      />
                    </div>
                  </CardContent>
                  <CardContent className="sort">
                    <fieldset className="grow basis-0">
                      <legend>
                        <label className="filter-header" htmlFor={sortUid}>
                          Sort by
                        </label>
                      </legend>
                      <select
                        id={sortUid}
                        value={state.search.sort}
                        onChange={(e) =>
                          dispatch({
                            type: "update-search",
                            search: { sort: e.target.value === "purchase_date" ? "purchase_date" : "recently_updated" },
                          })
                        }
                      >
                        <option value="recently_updated">Recently Updated</option>
                        <option value="purchase_date">Purchase Date</option>
                      </select>
                    </fieldset>
                  </CardContent>
                  {bundles.length > 0 ? (
                    <CardContent>
                      <fieldset className="grow basis-0">
                        <legend>
                          <label htmlFor={bundlesUid}>Bundles</label>
                        </legend>
                        <Select
                          inputId={bundlesUid}
                          instanceId={bundlesUid}
                          options={bundles}
                          value={bundles.filter(({ id }) => state.search.bundles.includes(id))}
                          onChange={(selectedOptions) =>
                            dispatch({
                              type: "update-search",
                              search: { bundles: selectedOptions.map(({ id }) => id) },
                            })
                          }
                          isMulti
                          isClearable
                        />
                      </fieldset>
                    </CardContent>
                  ) : null}
                  <CardContent className="creator">
                    <fieldset role="group" className="grow basis-0">
                      <legend className="filter-header">Creator</legend>
                      <label>
                        All Creators
                        <input
                          type="checkbox"
                          checked={state.search.creators.length === 0}
                          onClick={() => dispatch({ type: "update-search", search: { creators: [] } })}
                          readOnly
                        />
                      </label>
                      {(showingAllCreators ? creatorsWithProductCounts : creatorsWithProductCounts.slice(0, 5)).map(
                        (creator) => (
                          <label key={creator.id}>
                            {creator.name}
                            <span className="shrink-0 text-muted">{`(${creator.count})`}</span>
                            <input
                              type="checkbox"
                              checked={state.search.creators.includes(creator.id)}
                              onClick={() =>
                                dispatch({
                                  type: "update-search",
                                  search: {
                                    creators: state.search.creators.includes(creator.id)
                                      ? state.search.creators.filter((id) => id !== creator.id)
                                      : [...state.search.creators, creator.id],
                                  },
                                })
                              }
                              readOnly
                            />
                          </label>
                        ),
                      )}
                      <div>
                        {creatorsWithProductCounts.length > 5 && !showingAllCreators ? (
                          <button
                            className="cursor-pointer underline all-unset"
                            onClick={() => setShowingAllCreators(true)}
                          >
                            Show more
                          </button>
                        ) : null}
                      </div>
                    </fieldset>
                  </CardContent>
                  {archivedCount > 0 ? (
                    <CardContent className="archived">
                      <fieldset role="group" className="grow basis-0">
                        <label className="filter-archived">
                          Show archived only
                          <input
                            type="checkbox"
                            checked={state.search.showArchivedOnly}
                            readOnly
                            onClick={() =>
                              dispatch({
                                type: "update-search",
                                search: { showArchivedOnly: !state.search.showArchivedOnly },
                              })
                            }
                          />
                        </label>
                      </fieldset>
                    </CardContent>
                  ) : null}
                </>
              ) : null}
            </UICard>
          ) : null}
          <ProductCardGrid>
            {filteredResults.slice(0, resultsLimit).map((result) => (
              <Card
                key={result.purchase.id}
                result={result}
                onArchive={() =>
                  dispatch({
                    type: "set-archived",
                    purchaseId: result.purchase.id,
                    isArchived: !result.purchase.is_archived,
                  })
                }
                onDelete={(confirm = true) => (confirm ? setDeleting(result) : deletePurchase(result))}
              />
            ))}
          </ProductCardGrid>
        </div>
        <DeleteProductModal
          deleting={deleting}
          onCancel={() => setDeleting(null)}
          onDelete={(deleting) => {
            dispatch({ type: "delete-purchase", id: deleting.purchase.id });
            setDeleting(null);
          }}
        />
      </section>
    </Layout>
  );
}
