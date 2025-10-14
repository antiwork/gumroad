import * as React from "react";

import { getSearchResults, ProductFilter, SearchRequest, SearchResults } from "$app/data/search";
import { SORT_KEYS, PROFILE_SORT_KEYS } from "$app/parsers/product";
import { CurrencyCode, getShortCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

import { Card } from "./Card";

export const SORT_BY_LABELS = {
  default: "Default",
  highest_rated: "Highest rated",
  hot_and_new: "Hot and new",
  most_reviewed: "Most reviewed",
  newest: "Newest",
  page_layout: "Custom",
  price_asc: "Price (Low to High)",
  price_desc: "Price (High to Low)",
};

export type State = {
  params: SearchRequest;
  results: SearchResults | null;
  offset?: number | undefined;
};

export type Action =
  | { type: "set-params"; params: SearchRequest }
  | { type: "set-results"; results: SearchResults }
  | { type: "load-more" };

export const useSearchReducer = (initial: Omit<State, "offset">) => {
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const [state, dispatch] = React.useReducer(
    (state: State, action: Action) => {
      switch (action.type) {
        case "set-params": {
          const params = {
            ...action.params,
            taxonomy: action.params.taxonomy === "discover" ? undefined : action.params.taxonomy,
          };
          return { params, results: null, offset: action.params.from };
        }
        case "set-results":
          return { ...state, results: action.results };
        case "load-more":
          if (
            !state.results ||
            state.results.total < (state.offset ?? 1) + state.results.products.length ||
            activeRequest.current
          )
            return state;
          return {
            ...state,
            params: { ...state.params, from: (state.offset ?? 1) + state.results.products.length },
          };
      }
    },
    { ...initial, offset: initial.params.from },
  );

  useOnChange(
    asyncVoid(async () => {
      try {
        const request = getSearchResults(state.params);
        activeRequest.current = request;
        const results = await request.response;
        dispatch({
          type: "set-results",
          results:
            state.results == null
              ? results
              : { ...results, products: [...state.results.products, ...results.products] },
        });
        activeRequest.current = null;
      } catch (e) {
        if (!(e instanceof AbortError)) {
          assertResponseError(e);
          showAlert("Something went wrong. Please try refreshing the page.", "error");
        }
      }
    }),
    [state.params],
  );
  return [state, dispatch] as const;
};

type Props = {
  state: State;
  dispatchAction: React.Dispatch<Action>;
  currencyCode: CurrencyCode;
  title?: string | null;
  hideFilters?: boolean;
  disableFilters?: boolean;
  defaults?: SearchRequest;
  hideSort?: boolean;
  prependFilters?: React.ReactNode;
  appendFilters?: React.ReactNode;
  pagination?: "scroll" | "button";
};

const FilterCheckboxes = ({
  selection,
  setSelection,
  filters,
  disabled,
}: {
  filters: ProductFilter[];
  selection: string[];
  setSelection: (value: string[]) => void;
  disabled: boolean;
}) => {
  const [showingAll, setShowingAll] = React.useState(false);
  return (
    <>
      {(showingAll ? filters : filters.slice(0, 5)).map((option) => (
        <label key={option.key}>
          {option.key} ({option.doc_count})
          <input
            type="checkbox"
            checked={selection.includes(option.key)}
            disabled={disabled}
            onChange={() =>
              setSelection(
                selection.includes(option.key)
                  ? selection.filter((type) => type !== option.key)
                  : [...selection, option.key],
              )
            }
          />
        </label>
      ))}
      {filters.length > 5 && !showingAll ? (
        <button className="link" onClick={() => setShowingAll(true)}>
          Show more
        </button>
      ) : null}
    </>
  );
};

export const CardGrid = ({
  state,
  dispatchAction,
  title,
  hideFilters,
  disableFilters,
  currencyCode,
  defaults = {},
  prependFilters,
  appendFilters,
  hideSort,
  pagination = "scroll",
}: Props) => {
  const currencySymbol = getShortCurrencySymbol(currencyCode);
  const gridRef = React.useRef<HTMLDivElement | null>(null);

  const { results, params: searchParams } = state;
  useOnChange(() => {
    setEnteredMinPrice(searchParams.min_price ?? null);
    setEnteredMaxPrice(searchParams.max_price ?? null);
  }, [searchParams]);
  const updateParams = (newParams: Partial<SearchRequest>) => {
    const { from: _, ...params } = searchParams;
    dispatchAction({ type: "set-params", params: { ...params, ...newParams } });
  };

  const [enteredMinPrice, setEnteredMinPrice] = React.useState(searchParams.min_price ?? null);
  const [enteredMaxPrice, setEnteredMaxPrice] = React.useState(searchParams.max_price ?? null);

  const debouncedTrySetPrice = useDebouncedCallback((minPrice: number | null, maxPrice: number | null) => {
    trySetPrice(minPrice, maxPrice);
  }, 500);

  const trySetPrice = (minPrice: number | null, maxPrice: number | null) => {
    if (minPrice == null || maxPrice == null || maxPrice > minPrice) {
      updateParams({ min_price: minPrice ?? undefined, max_price: maxPrice ?? undefined });
    } else showAlert("Please set the price minimum to be lower than the maximum.", "error");
  };
  const resetFilters = () => dispatchAction({ type: "set-params", params: defaults });

  let anyFilters = false;
  for (const key of Object.keys(searchParams))
    if (
      !["from", "curated_product_ids"].includes(key) &&
      searchParams[key] != null &&
      searchParams[key] !== defaults[key]
    )
      anyFilters = true;

  React.useEffect(() => {
    if (pagination !== "scroll") return;
    const observer = new IntersectionObserver((e) => {
      if (e[0]?.isIntersecting) dispatchAction({ type: "load-more" });
    });
    if (results?.products && gridRef.current?.lastElementChild) observer.observe(gridRef.current.lastElementChild);
    return () => observer.disconnect();
  }, [pagination, results?.products]);

  const uid = React.useId();
  const minPriceUid = React.useId();
  const maxPriceUid = React.useId();
  const onProfile = !!searchParams.user_id;

  const concatFoundAndNotFound = (
    resultsData: ProductFilter[] | undefined,
    searchedKeys: ProductFilter["key"][] | undefined,
  ): ProductFilter[] => {
    const foundData = resultsData ?? [];
    const notFoundKeys = searchedKeys?.filter((s) => !foundData.some((f) => f.key === s)) ?? [];
    return notFoundKeys.map((key) => ({ key, doc_count: 0 })).concat(foundData);
  };
  const [tagsOpen, setTagsOpen] = React.useState(false);
  const [filetypesOpen, setFiletypesOpen] = React.useState(false);

  return (
    <div className="grid grid-cols-1 items-start gap-x-16 gap-y-8 lg:grid-cols-[var(--grid-cols-sidebar)]">
      {hideFilters ? null : (
        <div className="stack overflow-y-auto lg:sticky lg:inset-y-4 lg:max-h-[calc(100vh-2rem)]" aria-label="Filters">
          <header>
            {title ?? "Filters"}
            {anyFilters ? (
              <div className="text-right">
                <button className="link" onClick={resetFilters}>
                  Clear
                </button>
              </div>
            ) : null}
          </header>
          {prependFilters}
          {hideSort ? null : (
            <details>
              <summary>Sort by</summary>
              <fieldset role="group">
                {(onProfile ? PROFILE_SORT_KEYS : SORT_KEYS).map((key) => (
                  <label key={key}>
                    {SORT_BY_LABELS[key]}
                    <input
                      type="radio"
                      disabled={disableFilters}
                      name={`${uid}-sortBy`}
                      checked={(searchParams.sort ?? defaults.sort) === key}
                      onChange={() => updateParams({ sort: key })}
                    />
                  </label>
                ))}
              </fieldset>
            </details>
          )}
          {results?.tags_data.length || searchParams.tags?.length || tagsOpen ? (
            <details onToggle={() => setTagsOpen(!tagsOpen)}>
              <summary>Tags</summary>
              <fieldset role="group">
                <label>
                  All Products
                  <input
                    type="checkbox"
                    checked={!searchParams.tags?.length}
                    disabled={disableFilters || !searchParams.tags?.length}
                    onChange={() => updateParams({ tags: undefined })}
                  />
                </label>
                {results ? (
                  <FilterCheckboxes
                    filters={concatFoundAndNotFound(results.tags_data, searchParams.tags)}
                    selection={searchParams.tags ?? []}
                    setSelection={(tags) => updateParams({ tags })}
                    disabled={disableFilters ?? false}
                  />
                ) : null}
              </fieldset>
            </details>
          ) : null}
          {results?.filetypes_data.length || searchParams.filetypes?.length || filetypesOpen ? (
            <details onToggle={() => setFiletypesOpen(!filetypesOpen)}>
              <summary>Contains</summary>
              <fieldset role="group">
                {results ? (
                  <FilterCheckboxes
                    filters={concatFoundAndNotFound(results.filetypes_data, searchParams.filetypes)}
                    selection={searchParams.filetypes ?? []}
                    setSelection={(filetypes) => updateParams({ filetypes })}
                    disabled={disableFilters ?? false}
                  />
                ) : null}
              </fieldset>
            </details>
          ) : null}
          <details>
            <summary>Price</summary>
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                gridAutoFlow: "row",
                gap: "var(--spacer-3)",
              }}
            >
              <fieldset>
                <legend>
                  <label htmlFor={minPriceUid}>Minimum price</label>
                </legend>
                <div className="input">
                  <div className="pill">{currencySymbol}</div>
                  <NumberInput
                    onChange={(value) => {
                      setEnteredMinPrice(value);
                      debouncedTrySetPrice(value, enteredMaxPrice);
                    }}
                    value={enteredMinPrice ?? null}
                  >
                    {(props) => <input id={minPriceUid} placeholder="0" disabled={disableFilters} {...props} />}
                  </NumberInput>
                </div>
              </fieldset>
              <fieldset>
                <legend>
                  <label htmlFor={maxPriceUid}>Maximum price</label>
                </legend>
                <div className="input">
                  <div className="pill">{currencySymbol}</div>
                  <NumberInput
                    onChange={(value) => {
                      setEnteredMaxPrice(value);
                      debouncedTrySetPrice(enteredMinPrice, value);
                    }}
                    value={enteredMaxPrice ?? null}
                  >
                    {(props) => <input id={maxPriceUid} placeholder="∞" disabled={disableFilters} {...props} />}
                  </NumberInput>
                </div>
              </fieldset>
            </div>
          </details>
          {appendFilters}
        </div>
      )}
      {results?.products.length === 0 ? (
        <div className="placeholder">
          <Icon name="archive-fill" />
          No products found
        </div>
      ) : (
        <div>
          <ProductCardGrid ref={gridRef}>
            {/* The first 4 images are above the fold, so we eagerily load them */}
            {results?.products.map((result, idx) => <Card key={result.permalink} product={result} eager={idx < 4} />) ??
              Array(6)
                .fill(0)
                .map((_, i) => <div key={i} className="dummy" />)}
          </ProductCardGrid>
          {pagination === "button" &&
          !((state.results?.total ?? 0) < (state.offset ?? 1) + (state.results?.products.length ?? 0)) ? (
            <div className="mt-8 w-full text-center">
              <button className="button" onClick={() => dispatchAction({ type: "load-more" })}>
                Load more
              </button>
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
};
