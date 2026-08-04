// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { SearchResults } from "$app/data/search";

import { Action, CardGrid, State } from "$app/components/Product/CardGrid";

afterEach(cleanup);

const resultsWithFormats = (keys: string[]): SearchResults => ({
  total: 2,
  products: [],
  tags_data: [],
  filetypes_data: [],
  taxonomy_attributes_data: [
    {
      name: "format",
      label: "Format",
      filters: keys.map((key) => ({ key, doc_count: 2, label: key })),
    },
  ],
});

// A cross-taxonomy or stale taxonomy_attribute_filters token (not present in the current
// taxonomy_attributes_data) must not render as a checked facet or survive in search params —
// gp6858 review, greptile P1.
describe("CardGrid taxonomy attribute filters", () => {
  it("drops an invalid taxonomy_attribute_filters token instead of rendering it as a checked facet", () => {
    const state: State = {
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:cross-taxonomy-value"] },
      // The reducer always records the params a response was fetched with alongside it.
      resultsParams: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:cross-taxonomy-value"] },
      results: resultsWithFormats(["format:otf"]),
    };
    let lastAction: Action | undefined;
    const dispatchAction = (action: Action) => {
      lastAction = action;
    };

    render(<CardGrid state={state} dispatchAction={dispatchAction} currencyCode="usd" />);

    expect(screen.queryByText(/cross-taxonomy-value/iu)).toBeNull();
    expect(lastAction).toEqual({
      type: "set-params",
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: undefined },
    });
  });

  // Requests are not cancelled when params change, so an older search can resolve after a newer
  // one. Its facet set predates the newly-picked token and legitimately omits it — pruning on it
  // would clear the filter the user just picked and re-search broadened.
  it("does not prune when the facets on screen were fetched for different tokens", () => {
    const state: State = {
      // The user has just picked format:woff2; results still describe the previous search.
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:woff2"] },
      resultsParams: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:otf"] },
      results: resultsWithFormats(["format:otf"]),
    };
    let lastAction: Action | undefined;
    const dispatchAction = (action: Action) => {
      lastAction = action;
    };

    render(<CardGrid state={state} dispatchAction={dispatchAction} currencyCode="usd" />);

    expect(lastAction).toBeUndefined();
  });

  // A stale response for a previous taxonomy can share the exact token list with the current
  // one (e.g. format:shared retained across a category switch); its facets say nothing about
  // whether the token is valid in the CURRENT taxonomy — greptile P1 round 2.
  it("does not prune when the facets on screen were fetched for a different taxonomy", () => {
    const state: State = {
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:shared"] },
      resultsParams: { taxonomy: "design/icons", taxonomy_attribute_filters: ["format:shared"] },
      results: resultsWithFormats(["format:otf"]),
    };
    let lastAction: Action | undefined;
    const dispatchAction = (action: Action) => {
      lastAction = action;
    };

    render(<CardGrid state={state} dispatchAction={dispatchAction} currencyCode="usd" />);

    expect(lastAction).toBeUndefined();
  });

  it("does not prune before any response has been recorded for the current tokens", () => {
    const state: State = {
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:woff2"] },
      results: resultsWithFormats(["format:otf"]),
    };
    let lastAction: Action | undefined;
    const dispatchAction = (action: Action) => {
      lastAction = action;
    };

    render(<CardGrid state={state} dispatchAction={dispatchAction} currencyCode="usd" />);

    expect(lastAction).toBeUndefined();
  });

  it("still prunes when only unrelated params differ from the fetched ones", () => {
    const state: State = {
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:cross-taxonomy-value"], from: 10 },
      resultsParams: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:cross-taxonomy-value"] },
      results: resultsWithFormats(["format:otf"]),
    };
    let lastAction: Action | undefined;
    const dispatchAction = (action: Action) => {
      lastAction = action;
    };

    render(<CardGrid state={state} dispatchAction={dispatchAction} currencyCode="usd" />);

    expect(lastAction).toEqual({
      type: "set-params",
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: undefined },
    });
  });
});
