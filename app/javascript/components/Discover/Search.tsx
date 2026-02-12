import { router, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { escapeRegExp } from "$app/utils";

import { ComboBox } from "$app/components/ComboBox";
import { Icon } from "$app/components/Icons";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

import thumbnailPlaceholder from "$assets/images/placeholders/product-cover.png";

export type AutocompleteSearchResults = {
  products: {
    name: string;
    url: string;
    seller_name: string | null;
    thumbnail_url: string | null;
  }[];
  recent_searches: string[];
  viewed?: boolean;
};

export const Search = ({ query, setQuery }: { query?: string | undefined; setQuery: (query: string) => void }) => {
  const { autocomplete_results } = usePage<{ autocomplete_results?: AutocompleteSearchResults }>().props;

  const [enteredQuery, setEnteredQuery] = React.useState(query ?? "");
  useOnChange(() => setEnteredQuery(query ?? ""), [query]);

  const fetchAutocomplete = useDebouncedCallback(() => {
    router.reload({
      only: ["autocomplete_results"],
      data: { autocomplete_query: enteredQuery || undefined },
      preserveUrl: true,
    });
  }, 300);
  const [results, setResults] = React.useState<AutocompleteSearchResults | null>(autocomplete_results ?? null);
  const [autocompleteOpen, setAutocompleteOpen] = React.useState(false);

  useOnChange(() => {
    if (autocomplete_results) setResults(autocomplete_results);
  }, [autocomplete_results]);

  useOnChange(() => fetchAutocomplete(), [enteredQuery]);
  useOnChange(() => {
    if (autocompleteOpen && !results) fetchAutocomplete();
  }, [autocompleteOpen]);

  const highlightQuery = (text: string) => {
    const index = text.search(new RegExp(escapeRegExp(enteredQuery), "iu"));
    if (index === -1) return text;
    return (
      <>
        {text.slice(0, index)}
        <b>{text.slice(index, index + enteredQuery.length)}</b>
        {text.slice(index + enteredQuery.length)}
      </>
    );
  };

  const deleteRecentSearch = (searchQuery: string) => {
    if (results) setResults({ ...results, recent_searches: results.recent_searches.filter((q) => q !== searchQuery) });
    router.delete(Routes.discover_delete_search_suggestion_path({ query: searchQuery }), {
      preserveScroll: true,
      preserveState: true,
      only: [],
    });
  };

  const options = results ? [...results.recent_searches, ...results.products] : [];

  return (
    <ComboBox
      className="flex-1"
      open={autocompleteOpen ? options.length > 0 : false}
      onToggle={setAutocompleteOpen}
      editable
      input={(props) => (
        <div className="input">
          <Icon name="solid-search" />
          <input
            {...props}
            type="search"
            className="cursor-text!"
            placeholder="Search products"
            aria-label="Search products"
            value={enteredQuery}
            onKeyUp={(e) => {
              if (e.key === "Enter") {
                setQuery(enteredQuery);
                fetchAutocomplete.cancel();
              }
            }}
            onChange={(e) => {
              setEnteredQuery(e.target.value);
              setAutocompleteOpen(true);
            }}
            aria-autocomplete="list"
          />
        </div>
      )}
      options={options}
      option={(item, props, index) => (
        <>
          {index === results?.recent_searches.length ? (
            <h3 className="px-4 py-2">
              {enteredQuery ? "Products" : results.viewed ? "Keep shopping for" : "Trending"}
            </h3>
          ) : null}
          {typeof item === "string" ? (
            <div {...props}>
              <a href={Routes.discover_path({ query: item })} className="flex flex-1 items-center no-underline">
                <Icon name="clock-history" className="mr-2 text-muted" />
                {highlightQuery(item)}
              </a>
              <button onClick={() => deleteRecentSearch(item)} aria-label="Remove" className="cursor-pointer all-unset">
                <Icon name="x" className="text-muted" />
              </button>
            </div>
          ) : (
            <a {...props} href={item.url} className={cx("flex items-center gap-4 no-underline", props.className)}>
              <img
                src={item.thumbnail_url ?? thumbnailPlaceholder}
                alt={item.name}
                className="h-12 w-12 flex-none rounded border border-border object-cover"
              />
              <div>
                {highlightQuery(item.name)}
                <small>{item.seller_name ? `Product by ${item.seller_name}` : "Product"}</small>
              </div>
            </a>
          )}
        </>
      )}
    />
  );
};
