import { range } from "lodash-es";
import * as React from "react";
import { createCast, is } from "ts-safe-cast";

import { getRecommendedProducts } from "$app/data/discover";
import { SearchResults, SearchRequest } from "$app/data/search";
import { useScrollToElement } from "$app/hooks/useScrollToElement";
import { CardProduct } from "$app/parsers/product";
import { last } from "$app/utils/array";
import { classNames } from "$app/utils/classNames";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
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

import blackFridayImage from "$assets/images/illustrations/black_friday.svg";
import saleImage from "$assets/images/illustrations/sale.svg";

type Props = {
  currency_code: CurrencyCode;
  search_results: SearchResults;
  taxonomies_for_nav: Taxonomy[];
  recommended_products: CardProduct[];
  curated_product_ids: string[];
  show_black_friday_hero: boolean;
  is_black_friday_page: boolean;
  black_friday_offer_code: string;
  black_friday_stats: {
    active_deals_count: number;
    revenue_cents: number;
    average_discount_percentage: number;
  } | null;
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
    <section className="grid gap-4">
      <header className="flex items-center justify-between">
        <h2>{title}</h2>
        <div className="flex items-center gap-2">
          <button onClick={() => setActive((active + products.length - 1) % products.length)}>
            <Icon name="arrow-left" className="text-xl" />
          </button>
          {active + 1} / {products.length}
          <button onClick={() => setActive((active + products.length + 1) % products.length)}>
            <Icon name="arrow-right" className="text-xl" />
          </button>
        </div>
      </header>
      <div className="relative">
        <div
          className="override grid min-h-96 auto-cols-[min(20rem,60vw)] grid-flow-col gap-6 overflow-x-auto pb-1 [scrollbar-width:none] lg:auto-cols-[40rem] [&::-webkit-scrollbar]:hidden"
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

const BlackFridayBanner = ({
  stats,
  currencyCode,
}: {
  stats: { active_deals_count: number; revenue_cents: number; average_discount_percentage: number };
  currencyCode: CurrencyCode;
}) => (
  <div className="flex h-full shrink-0 items-center gap-x-4 [&>*]:flex-shrink-0">
    <span className="mx-2 inline-block text-lg text-black">✦</span>
    <span className="flex items-center text-xl font-medium text-black">BLACK FRIDAY IS LIVE</span>
    {stats.active_deals_count > 0 && (
      <>
        <span className="mx-2 inline-block text-lg text-black">✦</span>
        <span className="flex items-center text-xl font-medium text-black">
          <span className="mr-1.5 font-bold">{stats.active_deals_count.toLocaleString()}</span>ACTIVE DEALS
        </span>
      </>
    )}
    <span className="mx-2 inline-block text-lg text-black">✦</span>
    <span className="flex items-center text-xl font-medium text-black">CREATOR-MADE PRODUCTS</span>
    {stats.revenue_cents > 0 && (
      <>
        <span className="mx-2 inline-block text-lg text-black">✦</span>
        <span className="flex items-center text-xl font-medium text-black">
          <span className="mr-1.5 font-bold">
            {formatPriceCentsWithCurrencySymbol(currencyCode, stats.revenue_cents, { symbolFormat: "short" })}
          </span>
          IN SALES SO FAR
        </span>
      </>
    )}
    <span className="mx-2 inline-block text-lg text-black">✦</span>
    <span className="flex items-center text-xl font-medium text-black">BIG SAVINGS</span>
    {stats.average_discount_percentage > 0 && (
      <>
        <span className="mx-2 inline-block text-lg text-black">✦</span>
        <span className="flex items-center text-xl font-medium text-black">
          <span className="mr-1.5 font-bold">{stats.average_discount_percentage}%</span>AVERAGE DISCOUNT
        </span>
      </>
    )}
  </div>
);

// Featured products and search results overlap when there are no filters, so we skip over the featured products in the search request
// See DiscoverController::RECOMMENDED_PRODUCTS_COUNT
const recommendedProductsCount = 8;
const addInitialOffset = (params: SearchRequest) =>
  Object.entries(params).every(([key, value]) => !value || ["taxonomy", "curated_product_ids"].includes(key))
    ? { ...params, from: recommendedProductsCount + 1 }
    : params;

const BlackFridayButton = ({
  variant = "pink",
  size = "default",
  offerCode,
  taxonomy = undefined,
}: {
  variant?: "light" | "dark" | "pink";
  size?: "small" | "default";
  offerCode: string;
  taxonomy: string | undefined;
}) => {
  const variantClasses = {
    light: "bg-black text-white",
    dark: "bg-white text-black",
    pink: "bg-pink text-black",
  };

  const sizeClasses = {
    small: "h-12 px-3 text-base lg:h-12 lg:px-6 lg:text-base",
    default: "h-14 px-8 text-xl lg:h-16 lg:px-10 lg:text-xl",
  };

  const buttonClasses = classNames(
    "relative inline-flex rounded-sm no-underline items-center justify-center border border-black transition-all duration-150 group-hover:-translate-x-2 group-hover:-translate-y-2 z-3 w-full lg:w-auto",
    variantClasses[variant],
    sizeClasses[size],
  );

  const url = taxonomy
    ? Routes.discover_taxonomy_path(taxonomy, { offer_code: offerCode })
    : Routes.discover_path({ offer_code: offerCode });

  return (
    <div className="group relative inline-block">
      <div className="absolute inset-0 z-2 rounded-sm border border-black bg-yellow transition-transform duration-150"></div>
      <div className="absolute inset-0 z-1 rounded-sm border border-black bg-red transition-transform duration-150 group-hover:translate-x-2 group-hover:translate-y-2"></div>
      <a href={url} className={buttonClasses}>
        Get Black Friday deals
      </a>
    </div>
  );
};

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

    parseParams(["sort", "query", "offer_code"], (value) => value);
    parseParams(["min_price", "max_price", "rating"], (value) => Number(value));
    parseParams(["filetypes", "tags"], (value) => value.split(","));
    if (!parsedParams.sort) parsedParams.sort = defaultSortOrder;
    return parsedParams;
  };
  const [state, dispatch] = useSearchReducer({
    params: addInitialOffset(parseUrlParams(location)),
    results: props.search_results,
  });

  const isBlackFridayPage = state.params.offer_code === "BLACKFRIDAY2025";

  const resultsRef = useScrollToElement(isBlackFridayPage && props.show_black_friday_hero, undefined, [state.params]);

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
      serializeParams(["sort", "query", "offer_code"], (value) => value);
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

  const hasOfferCode = !!state.params.offer_code;

  useOnChange(
    asyncVoid(async () => {
      if (state.params.query || hasOfferCode) return;
      setRecommendedProducts([]);
      try {
        setRecommendedProducts(await getRecommendedProducts({ taxonomy: state.params.taxonomy }));
      } catch (e) {
        assertResponseError(e);
      }
    }),
    [state.params.taxonomy, hasOfferCode],
  );

  const isCuratedProducts =
    recommendedProducts[0] &&
    new URL(recommendedProducts[0].url).searchParams.get("recommended_by") === "products_for_you";

  const showRecommendedSections = recommendedProducts.length && !state.params.query && !hasOfferCode;

  return (
    <Layout
      taxonomyPath={taxonomyPath}
      taxonomiesForNav={props.taxonomies_for_nav}
      showTaxonomy
      onTaxonomyChange={(newTaxonomyPath) => {
        // Read from URL to avoid stale state when user clicks Clear then immediately navigates
        const currentUrl = new URL(window.location.href);
        const currentOfferCode = currentUrl.searchParams.get("offer_code") || undefined;
        dispatch({
          type: "set-params",
          params: addInitialOffset({
            taxonomy: newTaxonomyPath,
            sort: defaultSortOrder,
            offer_code: newTaxonomyPath ? currentOfferCode : undefined,
          }),
        });
      }}
      query={state.params.query}
      setQuery={(query) => dispatch({ type: "set-params", params: { query, taxonomy: taxonomyPath } })}
    >
      {props.show_black_friday_hero ? (
        <header className="relative flex flex-col items-center justify-center">
          <div className="relative flex min-h-[72vh] w-full flex-col items-center justify-center bg-black">
            <img
              src={saleImage}
              alt="Sale"
              className="absolute top-1/2 left-40 hidden w-32 -translate-y-1/2 rotate-[-24deg] object-contain md:left-12 md:block md:w-40 lg:left-36 lg:w-48 xl:left-60 xl:w-60"
              draggable={false}
            />
            <div className="relative">
              <img src={blackFridayImage} alt="Black Friday" className="max-w-96 object-contain" draggable={false} />
              <img
                src={saleImage}
                alt="Sale"
                className="absolute right-0 bottom-0 w-27.5 rotate-[16deg] object-contain md:hidden"
                draggable={false}
              />
            </div>
            <img
              src={saleImage}
              alt="Sale"
              className="absolute top-1/2 right-40 hidden w-32 -translate-y-1/2 rotate-[24deg] object-contain md:right-12 md:block md:w-40 lg:right-36 lg:w-48 xl:right-60 xl:w-60"
              draggable={false}
            />
            <div className="font-regular mx-12 text-center text-xl text-white">
              Snag creator-made deals <br className="block sm:hidden" /> before they're gone.
            </div>
            {!isBlackFridayPage && (
              <div className="mt-8 text-base">
                <BlackFridayButton offerCode={props.black_friday_offer_code} taxonomy={taxonomyPath} />
              </div>
            )}
          </div>
          <div className="h-14 w-full overflow-hidden border-b border-black bg-yellow-400">
            <div className="flex h-14 min-w-fit items-center gap-x-4 whitespace-nowrap hover:[animation-play-state:paused] motion-safe:animate-[marquee-scroll_80s_linear_infinite] motion-reduce:animate-none">
              {props.black_friday_stats ? (
                <>
                  {/* Duplicate enough times to ensure seamless infinite scroll */}
                  {(() => {
                    const stats = props.black_friday_stats;
                    return Array.from({ length: 5 }, (_, i) => (
                      <BlackFridayBanner key={i} stats={stats} currencyCode={props.currency_code} />
                    ));
                  })()}
                </>
              ) : null}
            </div>
          </div>
        </header>
      ) : null}
      <div className="grid gap-16! px-4 py-16 lg:ps-16 lg:pe-16">
        {showRecommendedSections ? (
          <ProductsCarousel
            products={recommendedProducts}
            title={isCuratedProducts ? "Recommended" : "Featured products"}
          />
        ) : null}
        <section ref={resultsRef} className="flex flex-col gap-4">
          <div style={{ display: "flex", justifyContent: "space-between", gap: "var(--spacer-2)", flexWrap: "wrap" }}>
            <h2>
              {state.params.query || hasOfferCode
                ? state.results?.products.length
                  ? `Showing 1-${state.results.products.length} of ${state.results.total} products`
                  : null
                : sortTitles[is<keyof typeof sortTitles>(state.params.sort) ? state.params.sort : "trending"]}
            </h2>
            {state.params.query || hasOfferCode ? null : (
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
            hideSort={!state.params.query && !hasOfferCode}
            defaults={{
              taxonomy: state.params.taxonomy,
              query: state.params.query,
              sort: state.params.query || hasOfferCode ? "default" : state.params.sort,
            }}
            appendFilters={
              <>
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
                {hasOfferCode ? (
                  <details open>
                    <summary>Offer code</summary>
                    <div className="flex items-center justify-between gap-2 py-1">
                      <span>BLACKFRIDAY2025</span>
                      <button
                        onClick={() => updateParams({ offer_code: undefined })}
                        className="flex items-center justify-center"
                        aria-label="Remove offer code filter"
                      >
                        <Icon name="x" />
                      </button>
                    </div>
                  </details>
                ) : null}
              </>
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
