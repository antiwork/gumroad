import range from "lodash/range";
import * as React from "react";
import { createCast, is } from "ts-safe-cast";

import { getRecommendedProducts } from "$app/data/discover";
import { SearchResults, SearchRequest } from "$app/data/search";
import { CardProduct } from "$app/parsers/product";
import { last } from "$app/utils/array";
import { CurrencyCode } from "$app/utils/currency";
import { discoverTitleGenerator, Taxonomy } from "$app/utils/discover";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Discover/Layout";
import { RecommendedWishlists } from "$app/components/Discover/RecommendedWishlists";
import { Icon } from "$app/components/Icons";
import { HorizontalCard } from "$app/components/Product/Card";
import { CardGrid, useSearchReducer } from "$app/components/Product/CardGrid";
import { RatingStars } from "$app/components/RatingStars";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useOnChange } from "$app/components/useOnChange";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useScrollableCarousel } from "$app/components/useScrollableCarousel";

type Props = {
  currency_code: CurrencyCode;
  search_results: SearchResults;
  taxonomies_for_nav: Taxonomy[];
  recommended_products: CardProduct[];
  curated_product_ids: string[];
};

const sortTitles = {
  curated: "Curated for you",
  trending: "On the market",
  hot_and_new: "Hot and new products",
  best_sellers: "Best selling products",
};

const ProductsCarousel = ({ products, title }: { products: CardProduct[]; title: string }) => {
  const [active, setActive] = React.useState(0);
  const { itemsRef, handleScroll } = useScrollableCarousel(active, setActive);
  const [dragStart, setDragStart] = React.useState<number | null>(null);

  return (
    <section className="carousel-section">
      <header>
        <h2>{title}</h2>
        <div className="actions">
          <button onClick={() => setActive((active + products.length - 1) % products.length)}>
            <Icon name="arrow-left" />
          </button>
          {active + 1} / {products.length}
          <button onClick={() => setActive((active + products.length + 1) % products.length)}>
            <Icon name="arrow-right" />
          </button>
        </div>
      </header>
      <div className="carousel">
        <div
          className="items"
          ref={itemsRef}
          style={{ scrollSnapType: dragStart != null ? "none" : undefined }}
          onScroll={handleScroll}
          onMouseDown={(e) => setDragStart(e.clientX)}
          onMouseMove={(e) => {
            if (dragStart == null || !itemsRef.current) return;
            itemsRef.current.scrollLeft -= e.movementX;
          }}
          onClick={(e) => {
            if (dragStart != null && Math.abs(e.clientX - dragStart) > 30) e.preventDefault();
            setDragStart(null);
          }}
          onMouseOut={() => setDragStart(null)}
        >
          {products.map((product, idx) => (
            // Only the first 3 cards are visible, so we can set eager loading for them
            <HorizontalCard key={product.id} product={product} big eager={idx < 3} />
          ))}
        </div>
      </div>
    </section>
  );
};

// Featured products and search results overlap when there are no filters, so we skip over the featured products in the search request
// See DiscoverController::RECOMMENDED_PRODUCTS_COUNT
const recommendedProductsCount = 8;
const addInitialOffset = (params: SearchRequest) =>
  Object.entries(params).every(([key, value]) => !value || ["taxonomy", "curated_product_ids"].includes(key))
    ? { ...params, from: recommendedProductsCount + 1 }
    : params;

const Discover = (props: Props) => {
  const location = useOriginalLocation();

  const defaultSortOrder = props.curated_product_ids.length > 0 ? "curated" : undefined;
  const parseUrlParams = (href: string) => {
    const url = new URL(href);
    const parsedParams: SearchRequest = {
      taxonomy: url.pathname === Routes.discover_path() ? undefined : url.pathname.replace("/", ""),
      curated_product_ids: props.curated_product_ids.slice(
        url.pathname === Routes.discover_path() ? recommendedProductsCount : 0,
      ),
    };

    function parseParams<T extends keyof SearchRequest>(keys: T[], transform: (value: string) => SearchRequest[T]) {
      for (const key of keys) {
        const value = url.searchParams.get(key);
        parsedParams[key] = value ? transform(value) : undefined;
      }
    }

    parseParams(["sort", "query"], (value) => value);
    parseParams(["min_price", "max_price", "rating"], (value) => Number(value));
    parseParams(["filetypes", "tags"], (value) => value.split(","));
    if (!parsedParams.sort) parsedParams.sort = defaultSortOrder;
    return parsedParams;
  };
  const [state, dispatch] = useSearchReducer({
    params: addInitialOffset(parseUrlParams(location)),
    results: props.search_results,
  });

  const fromUrl = React.useRef(false);
  React.useEffect(() => {
    if (!fromUrl.current) {
      // don't pushState if we're already loading from history state
      const url = new URL(window.location.href);
      if (state.params.taxonomy) {
        url.pathname = state.params.taxonomy;
      } else if (url.pathname !== Routes.discover_path()) {
        url.pathname = Routes.discover_path();
      }
      const serializeParams = <T extends keyof SearchRequest>(
        keys: T[],
        transform: (value: NonNullable<SearchRequest[T]>) => string,
      ) => {
        for (const key of keys) {
          const value = state.params[key];
          if (value && (!Array.isArray(value) || value.length)) url.searchParams.set(key, transform(value));
          else url.searchParams.delete(key);
        }
      };
      serializeParams(["sort", "query"], (value) => value);
      serializeParams(["min_price", "max_price", "rating"], (value) => value.toString());
      serializeParams(["filetypes", "tags"], (value) => value.join(","));
      window.history.pushState(state.params, "", url);
    } else fromUrl.current = false;
    document.title = discoverTitleGenerator(state.params, props.taxonomies_for_nav);
  }, [state.params]);
  React.useEffect(() => {
    const parseUrl = () => {
      fromUrl.current = true;
      const newParams = parseUrlParams(window.location.href);
      dispatch({
        type: "set-params",
        params: addInitialOffset(newParams),
      });
    };
    window.addEventListener("popstate", parseUrl);
    return () => window.removeEventListener("popstate", parseUrl);
  }, [state.params.taxonomy]);

  const taxonomyPath = state.params.taxonomy;

  const updateParams = (newParams: Partial<SearchRequest>) =>
    dispatch({ type: "set-params", params: { ...state.params, from: undefined, ...newParams } });

  const [recommendedProducts, setRecommendedProducts] = React.useState<CardProduct[]>(props.recommended_products);
  useOnChange(
    asyncVoid(async () => {
      if (state.params.query) return;
      setRecommendedProducts([]);
      try {
        setRecommendedProducts(await getRecommendedProducts({ taxonomy: state.params.taxonomy }));
      } catch (e) {
        assertResponseError(e);
      }
    }),
    [state.params.taxonomy],
  );

  const isCuratedProducts =
    recommendedProducts[0] &&
    new URL(recommendedProducts[0].url).searchParams.get("recommended_by") === "products_for_you";

  const showRecommendedSections = recommendedProducts.length && !state.params.query;

  return (
    <Layout
      taxonomyPath={taxonomyPath}
      taxonomiesForNav={props.taxonomies_for_nav}
      showTaxonomy
      onTaxonomyChange={(newTaxonomyPath) =>
        dispatch({
          type: "set-params",
          params: addInitialOffset({ taxonomy: newTaxonomyPath, sort: defaultSortOrder }),
        })
      }
      query={state.params.query}
      setQuery={(query) => dispatch({ type: "set-params", params: { query, taxonomy: taxonomyPath } })}
    >
      <div className="grid gap-16! px-4 py-16 lg:ps-16 lg:pe-16">
        {showRecommendedSections ? (
          <ProductsCarousel
            products={recommendedProducts}
            title={isCuratedProducts ? "Recommended" : "Featured products"}
          />
        ) : null}
        <section className="paragraphs">
          <div style={{ display: "flex", justifyContent: "space-between", gap: "var(--spacer-2)", flexWrap: "wrap" }}>
            <h2>
              {state.params.query
                ? state.results?.products.length
                  ? `Showing 1-${state.results.products.length} of ${state.results.total} products`
                  : null
                : sortTitles[is<keyof typeof sortTitles>(state.params.sort) ? state.params.sort : "trending"]}
            </h2>
            {state.params.query ? null : (
              <Tabs>
                {props.curated_product_ids.length > 0 ? (
                  <Tab
                    isSelected={state.params.sort === "curated"}
                    onClick={() =>
                      updateParams({
                        sort: "curated",
                        curated_product_ids: props.curated_product_ids.slice(recommendedProductsCount),
                      })
                    }
                  >
                    Curated
                  </Tab>
                ) : null}
                <Tab
                  isSelected={!state.params.sort || state.params.sort === "default"}
                  onClick={() => updateParams({ sort: undefined })}
                >
                  Trending
                </Tab>
                {props.curated_product_ids.length === 0 ? (
                  <Tab
                    isSelected={state.params.sort === "best_sellers"}
                    onClick={() => updateParams({ sort: "best_sellers" })}
                  >
                    Best Sellers
                  </Tab>
                ) : null}
                <Tab
                  isSelected={state.params.sort === "hot_and_new"}
                  onClick={() => updateParams({ sort: "hot_and_new" })}
                >
                  Hot &amp; New
                </Tab>
              </Tabs>
            )}
          </div>
          <CardGrid
            state={state}
            dispatchAction={dispatch}
            currencyCode={props.currency_code}
            hideSort={!state.params.query}
            defaults={{
              taxonomy: state.params.taxonomy,
              query: state.params.query,
              sort: state.params.query ? "default" : state.params.sort,
            }}
            appendFilters={
              <details>
                <summary>Rating</summary>
                <fieldset role="group">
                  {range(4, 0).map((number) => (
                    <label key={number}>
                      <span className="flex shrink-0 items-center gap-1">
                        <RatingStars rating={number} />
                        and up
                      </span>
                      <input
                        type="radio"
                        value={number}
                        aria-label={`${number} ${number === 1 ? "star" : "stars"} and up`}
                        checked={number === state.params.rating}
                        readOnly
                        onClick={() =>
                          updateParams(state.params.rating === number ? { rating: undefined } : { rating: number })
                        }
                      />
                    </label>
                  ))}
                </fieldset>
              </details>
            }
            pagination="button"
          />
        </section>
        {showRecommendedSections ? (
          <RecommendedWishlists
            taxonomy={taxonomyPath ?? null}
            curatedProductIds={props.curated_product_ids}
            title={
              taxonomyPath
                ? `Wishlists for ${props.taxonomies_for_nav.find((t) => t.slug === last(taxonomyPath.split("/")))?.label}`
                : "Wishlists you might like"
            }
          />
        ) : null}
      </div>
    </Layout>
  );
};

export default register({ component: Discover, propParser: createCast() });
