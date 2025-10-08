import { produce } from "immer";
import * as React from "react";
import { createCast, is } from "ts-safe-cast";

import { deletePurchasedProduct, setPurchaseArchived } from "$app/data/library";
import { ProductNativeType } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";
import { writeQueryParams } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Layout } from "$app/components/Library/Layout";
import { Modal } from "$app/components/Modal";
import { Popover } from "$app/components/Popover";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
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
    <article className="product-card relative">
      <figure>
        <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
      </figure>
      <header>
        {purchase.download_url ? (
          <a href={purchase.download_url} className="stretched-link" aria-label={name}>
            <h3 itemProp="name">{name}</h3>
          </a>
        ) : (
          <h3 itemProp="name">{name}</h3>
        )}
      </header>
      <footer className="relative">
        {product.creator ? (
          <AuthorByline
            name={product.creator.name}
            profileUrl={product.creator.profile_url}
            avatarUrl={product.creator.avatar_url ?? undefined}
          />
        ) : (
          <div className="user" />
        )}
        <Popover
          aria-label="Open product action menu"
          trigger={<Icon name="three-dots" />}
          open={isPopoverOpen}
          onToggle={setIsPopoverOpen}
        >
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
        </Popover>
      </footer>
    </article>
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
  creators: { id: string; name: string; count: number }[];
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

const LibraryPage = ({ results, creators, bundles, reviews_page_enabled, following_wishlists_enabled }: Props) => {
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

  const [resultsLimit, setResultsLimit] = React.useState(9);
  React.useEffect(() => setResultsLimit(9), [filteredResults]);

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
    url.searchParams.delete("purchase_id");
    window.history.replaceState(window.history.state, "", url.toString());
    if (purchaseIds.length > 0) {
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

  return (
    <Layout
      selectedTab="purchases"
      onScrollToBottom={() => setResultsLimit((prevNumberOfResults) => prevNumberOfResults + 9)}
      reviewsPageEnabled={reviews_page_enabled}
      followingWishlistsEnabled={following_wishlists_enabled}
    >
      <section className="space-y-4 p-4 md:p-8">
        {state.results.length === 0 || showArchivedNotice ? (
          <div className="placeholder">
            {state.results.length === 0 ? (
              <figure>
                <img src={placeholder} />
              </figure>
            ) : null}
            {state.results.length === 0 ? (
              <>
                <h2 className="library-header">You haven't bought anything... yet!</h2>
                Once you do, it'll show up here so you can download, watch, read, or listen to all your purchases.
                <a href={discoverUrl} className="button accent">
                  Discover products
                </a>
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
          </div>
        ) : null}
        {archivedCount > 0 && !state.search.showArchivedOnly && !showArchivedNotice ? (
          <div role="status" className="info mb-5">
            <span>
              You have {archivedCount} archived purchase{archivedCount === 1 ? "" : "s"}.{" "}
              <button
                type="button"
                className="link"
                onClick={() => dispatch({ type: "update-search", search: { showArchivedOnly: true } })}
              >
                Click here to view
              </button>
            </span>
          </div>
        ) : null}
        <div className="with-sidebar">
          {!showArchivedNotice && (hasParams || archivedCount > 0 || state.results.length > 9) ? (
            <div className="stack">
              <header>
                <div>
                  {filteredResults.length
                    ? `Showing 1-${Math.min(filteredResults.length, resultsLimit)} of ${filteredResults.length} products`
                    : "No products found"}
                </div>
                {isDesktop ? null : (
                  <button className="link" onClick={() => setMobileFiltersExpanded(!mobileFiltersExpanded)}>
                    Filter
                  </button>
                )}
              </header>
              {isDesktop || mobileFiltersExpanded ? (
                <>
                  <div>
                    <div className="input input-wrapper product-search__wrapper">
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
                  </div>
                  <div className="sort">
                    <fieldset>
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
                  </div>
                  {bundles.length > 0 ? (
                    <div>
                      <fieldset>
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
                    </div>
                  ) : null}
                  <div className="creator">
                    <fieldset role="group">
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
                      {(showingAllCreators ? creators : creators.slice(0, 5)).map((creator) => (
                        <label key={creator.id}>
                          {creator.name}
                          <span className="text-muted shrink-0">{`(${creator.count})`}</span>
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
                      ))}
                      <div>
                        {creators.length > 5 && !showingAllCreators ? (
                          <button className="link" onClick={() => setShowingAllCreators(true)}>
                            Show more
                          </button>
                        ) : null}
                      </div>
                    </fieldset>
                  </div>
                  {archivedCount > 0 ? (
                    <div className="archived">
                      <fieldset role="group">
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
                    </div>
                  ) : null}
                </>
              ) : null}
            </div>
          ) : null}
          <div className="product-card__column product-card__grid product-card-grid">
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
          </div>
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
};

export default register({ component: LibraryPage, propParser: createCast() });
