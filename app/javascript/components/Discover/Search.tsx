import cx from "classnames";
import * as React from "react";

import { getAutocompleteSearchResults, AutocompleteSearchResults, deleteAutocompleteSearch } from "$app/data/discover";
import { escapeRegExp } from "$app/utils";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { ComboBox } from "$app/components/ComboBox";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

import thumbnailPlaceholder from "$assets/images/placeholders/product-cover.png";

export const Search = ({ query, setQuery }: { query?: string | undefined; setQuery: (query: string) => void }) => {
  const [enteredQuery, setEnteredQuery] = React.useState(query ?? "");
  useOnChange(() => setEnteredQuery(query ?? ""), [query]);

  const cancelAutocomplete = React.useRef<() => void>();
  const fetchAutocomplete = useDebouncedCallback(
    asyncVoid(async () => {
      try {
        const abortController = new AbortController();
        cancelAutocomplete.current = () => abortController.abort();
        setResults(await getAutocompleteSearchResults({ query: enteredQuery }, abortController.signal));
      } catch (e) {
        assertResponseError(e);
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    }),
    300,
  );
  const [results, setResults] = React.useState<AutocompleteSearchResults | null>(null);
  const [autocompleteOpen, setAutocompleteOpen] = React.useState(false);

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

  const deleteRecentSearch = (query: string) => {
    void deleteAutocompleteSearch({ query });
    if (results) setResults({ ...results, recent_searches: results.recent_searches.filter((q) => q !== query) });
  };

  const options = results ? [...results.recent_searches, ...results.products] : [];

  return (
    <ComboBox
      style={{ flex: 1 }}
      open={autocompleteOpen ? options.length > 0 : false}
      onToggle={setAutocompleteOpen}
      editable
      input={(props) => (
        <div className="input">
          <Icon name="solid-search" />
          <input
            {...props}
            type="search"
            className="!cursor-text"
            placeholder="Search products"
            aria-label="Search products"
            value={enteredQuery}
            onKeyUp={(e) => {
              if (e.key === "Enter") {
                setQuery(enteredQuery);
                fetchAutocomplete.cancel();
                cancelAutocomplete.current?.();
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
            <h3>{enteredQuery ? "Products" : results.viewed ? "Keep shopping for" : "Trending"}</h3>
          ) : null}
          {typeof item === "string" ? (
            <div {...props}>
              <a href={Routes.discover_path({ query: item })} className="flex flex-1 items-center no-underline">
                <Icon name="clock-history" className="text-muted mr-2" />
                {highlightQuery(item)}
              </a>
              <button onClick={() => deleteRecentSearch(item)} aria-label="Remove">
                <Icon name="x" className="text-muted" />
              </button>
            </div>
          ) : (
            <a {...props} href={item.url} className={cx("flex items-center gap-4 no-underline", props.className)}>
              <img src={item.thumbnail_url ?? thumbnailPlaceholder} alt={item.name} />
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
