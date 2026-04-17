import { ChevronDown } from "@boxicons/react";
import * as React from "react";

import { SearchRequest } from "$app/data/search";
import { SORT_KEYS } from "$app/parsers/product";
import { CurrencyCode, getShortCurrencySymbol } from "$app/utils/currency";

import { NumberInput } from "$app/components/NumberInput";
import { Action, FilterCheckboxes, RatingFilterOptions, SORT_BY_LABELS, State } from "$app/components/Product/CardGrid";
import { showAlert } from "$app/components/server-components/Alert";
import { BottomSheet, BottomSheetFooter, BottomSheetHeader } from "$app/components/ui/BottomSheet";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Radio } from "$app/components/ui/Radio";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

type FilterKey = "sort" | "tags" | "contains" | "price" | "rating";

type MobileFilterBarProps = {
  state: State;
  dispatchAction: React.Dispatch<Action>;
  defaults: SearchRequest;
  currencyCode: CurrencyCode;
  hideSort?: boolean;
  hasOfferCode?: boolean;
};

export const MobileFilterBar = ({
  state,
  dispatchAction,
  defaults,
  currencyCode,
  hideSort,
  hasOfferCode,
}: MobileFilterBarProps) => {
  const currencySymbol = getShortCurrencySymbol(currencyCode);
  const [openFilter, setOpenFilter] = React.useState<FilterKey | null>(null);

  const { params: searchParams } = state;
  const lastResultsRef = React.useRef(state.results);
  if (state.results != null) lastResultsRef.current = state.results;
  const results = state.results ?? lastResultsRef.current;

  const updateParams = (newParams: Partial<SearchRequest>) => {
    const { from: _, ...params } = searchParams;
    dispatchAction({ type: "set-params", params: { ...params, ...newParams } });
  };

  const [enteredMinPrice, setEnteredMinPrice] = React.useState(searchParams.min_price ?? null);
  const [enteredMaxPrice, setEnteredMaxPrice] = React.useState(searchParams.max_price ?? null);

  useOnChange(() => {
    setEnteredMinPrice(searchParams.min_price ?? null);
    setEnteredMaxPrice(searchParams.max_price ?? null);
  }, [searchParams]);

  const debouncedTrySetPrice = useDebouncedCallback((minPrice: number | null, maxPrice: number | null) => {
    trySetPrice(minPrice, maxPrice);
  }, 500);

  const trySetPrice = (minPrice: number | null, maxPrice: number | null) => {
    if (minPrice == null || maxPrice == null || maxPrice > minPrice) {
      updateParams({ min_price: minPrice ?? undefined, max_price: maxPrice ?? undefined });
    } else showAlert("Please set the price minimum to be lower than the maximum.", "error");
  };

  const hasActiveFilters = Object.keys(searchParams).some(
    (key) =>
      !["from", "curated_product_ids"].includes(key) &&
      searchParams[key] != null &&
      searchParams[key] !== defaults[key],
  );

  const uid = React.useId();
  const minPriceUid = React.useId();
  const maxPriceUid = React.useId();

  const concatFoundAndNotFound = (
    resultsData: { key: string; doc_count: number }[] | undefined,
    searchedKeys: string[] | undefined,
  ) => {
    const foundData = resultsData ?? [];
    const notFoundKeys = searchedKeys?.filter((s) => !foundData.some((f) => f.key === s)) ?? [];
    return notFoundKeys.map((key) => ({ key, doc_count: 0 })).concat(foundData);
  };

  const filters: { key: FilterKey; label: string; title: string; active: boolean; visible: boolean; content: React.ReactNode }[] = [
    {
      key: "sort",
      title: "Sort by",
      label: searchParams.sort !== defaults.sort && searchParams.sort != null
        ? `Sort: ${SORT_BY_LABELS[searchParams.sort as keyof typeof SORT_BY_LABELS]}`
        : "Sort by",
      active: searchParams.sort !== defaults.sort && searchParams.sort != null,
      visible: !hideSort,
      content: (
        <Fieldset role="group">
          {SORT_KEYS.map((key) => (
            <Label key={key} className="w-full">
              {SORT_BY_LABELS[key]}
              <Radio
                wrapperClassName="ml-auto"
                name={`${uid}-mobile-sortBy`}
                checked={(searchParams.sort ?? defaults.sort) === key}
                onChange={() => updateParams({ sort: key })}
              />
            </Label>
          ))}
        </Fieldset>
      ),
    },
    {
      key: "tags",
      title: "Tags",
      label: (searchParams.tags?.length ?? 0) > 0 ? `Tags (${searchParams.tags!.length})` : "Tags",
      active: (searchParams.tags?.length ?? 0) > 0,
      visible: (results?.tags_data?.length ?? 0) > 0 || (searchParams.tags?.length ?? 0) > 0,
      content: (
        <Fieldset role="group">
          <Label className="w-full">
            All Products
            <Checkbox
              wrapperClassName="ml-auto"
              checked={!searchParams.tags?.length}
              disabled={!searchParams.tags?.length}
              onChange={() => updateParams({ tags: undefined })}
            />
          </Label>
          {results ? (
            <FilterCheckboxes
              filters={concatFoundAndNotFound(results.tags_data, searchParams.tags)}
              selection={searchParams.tags ?? []}
              setSelection={(tags) => updateParams({ tags })}
              disabled={false}
            />
          ) : null}
        </Fieldset>
      ),
    },
    {
      key: "contains",
      title: "Contains",
      label: (searchParams.filetypes?.length ?? 0) > 0 ? `Contains (${searchParams.filetypes!.length})` : "Contains",
      active: (searchParams.filetypes?.length ?? 0) > 0,
      visible: (results?.filetypes_data?.length ?? 0) > 0 || (searchParams.filetypes?.length ?? 0) > 0,
      content: (
        <Fieldset role="group">
          {results ? (
            <FilterCheckboxes
              filters={concatFoundAndNotFound(results.filetypes_data, searchParams.filetypes)}
              selection={searchParams.filetypes ?? []}
              setSelection={(filetypes) => updateParams({ filetypes })}
              disabled={false}
            />
          ) : null}
        </Fieldset>
      ),
    },
    {
      key: "price",
      title: "Price",
      label: (() => {
        const minSet = searchParams.min_price != null;
        const maxSet = searchParams.max_price != null;
        if (minSet && maxSet) return `${currencySymbol}${searchParams.min_price}\u2013${currencySymbol}${searchParams.max_price}`;
        if (minSet) return `${currencySymbol}${searchParams.min_price}+`;
        if (maxSet) return `Up to ${currencySymbol}${searchParams.max_price}`;
        return "Price";
      })(),
      active: searchParams.min_price != null || searchParams.max_price != null,
      visible: true,
      content: (
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
            gridAutoFlow: "row",
            gap: "var(--spacer-3)",
          }}
        >
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={minPriceUid}>Minimum price</Label>
            </FieldsetTitle>
            <InputGroup>
              <Pill className="-ml-2 shrink-0">{currencySymbol}</Pill>
              <NumberInput
                onChange={(value) => {
                  setEnteredMinPrice(value);
                  debouncedTrySetPrice(value, enteredMaxPrice);
                }}
                value={enteredMinPrice ?? null}
              >
                {(props) => <Input id={minPriceUid} placeholder="0" {...props} />}
              </NumberInput>
            </InputGroup>
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={maxPriceUid}>Maximum price</Label>
            </FieldsetTitle>
            <InputGroup>
              <Pill className="-ml-2 shrink-0">{currencySymbol}</Pill>
              <NumberInput
                onChange={(value) => {
                  setEnteredMaxPrice(value);
                  debouncedTrySetPrice(enteredMinPrice, value);
                }}
                value={enteredMaxPrice ?? null}
              >
                {(props) => <Input id={maxPriceUid} placeholder="∞" {...props} />}
              </NumberInput>
            </InputGroup>
          </Fieldset>
        </div>
      ),
    },
    {
      key: "rating",
      title: "Rating",
      label: searchParams.rating != null ? `${searchParams.rating}+ stars` : "Rating",
      active: searchParams.rating != null,
      visible: true,
      content: (
        <RatingFilterOptions
          rating={searchParams.rating}
          onRatingChange={(rating) => updateParams({ rating })}
        />
      ),
    },
  ];

  const visibleFilters = filters.filter((f) => f.visible);

  return (
    <>
      <div
        role="toolbar"
        aria-label="Filters"
        className="flex overflow-x-auto gap-2 px-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {visibleFilters.map((filter) => (
          <Pill key={filter.key} asChild className={`shrink-0 cursor-pointer ${filter.active ? "bg-accent/20 border-foreground" : "bg-transparent"}`}>
            <button onClick={() => setOpenFilter(filter.key)} aria-haspopup="dialog" className="inline-flex items-center gap-1">
              {filter.label}
              <ChevronDown className="size-4" />
            </button>
          </Pill>
        ))}
        {hasOfferCode ? (
          <Pill asChild color="primary" className="shrink-0 cursor-pointer">
            <button onClick={() => updateParams({ offer_code: undefined })}>
              {searchParams.offer_code}
            </button>
          </Pill>
        ) : null}
        {hasActiveFilters ? (
          <Pill asChild className="shrink-0 cursor-pointer bg-transparent">
            <button onClick={() => dispatchAction({ type: "set-params", params: defaults })}>Clear all</button>
          </Pill>
        ) : null}
      </div>

      {filters.map((filter) => (
        <BottomSheet
          key={filter.key}
          open={openFilter === filter.key}
          onOpenChange={(open) => { if (!open) setOpenFilter(null); }}
        >
          <BottomSheetHeader>{filter.title}</BottomSheetHeader>
          {filter.content}
          <BottomSheetFooter />
        </BottomSheet>
      ))}
    </>
  );
};
