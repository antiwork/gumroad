// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Action, CardGrid, State } from "$app/components/Product/CardGrid";

afterEach(cleanup);

// A cross-taxonomy or stale taxonomy_attribute_filters token (not present in the current
// taxonomy_attributes_data) must not render as a checked facet or survive in search params —
// gp6858 review, greptile P1.
describe("CardGrid taxonomy attribute filters", () => {
  it("drops an invalid taxonomy_attribute_filters token instead of rendering it as a checked facet", () => {
    const state: State = {
      params: { taxonomy: "design/fonts", taxonomy_attribute_filters: ["format:cross-taxonomy-value"] },
      results: {
        total: 2,
        products: [],
        tags_data: [],
        filetypes_data: [],
        taxonomy_attributes_data: [
          {
            name: "format",
            label: "Format",
            filters: [{ key: "format:otf", doc_count: 2, label: "OTF" }],
          },
        ],
      },
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
});
