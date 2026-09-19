// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { SearchRequest } from "$app/data/search";
import { RateLimitError } from "$app/utils/request";

// A storefront products section sends `ids` on top of the usual search params.
type SectionSearchRequest = SearchRequest & { ids: string[] };

import { CardGrid, State, useSearchReducer } from "$app/components/Product/CardGrid";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/data/search", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/data/search")>()),
  getSearchResults: vi.fn(),
}));

const { showAlert } = vi.mocked(await import("$app/components/server-components/Alert"));
const { getSearchResults } = vi.mocked(await import("$app/data/search"));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const results = { total: 1, products: [], tags_data: [], filetypes_data: [], taxonomy_attributes_data: [] };

// A storefront products section: one section of one profile, exactly the request shape that burned
// ~305k requests from a single IP.
// One section of one profile: the request shape a storefront section refetch produces.
const sectionParams = (): SectionSearchRequest => ({
  sort: "price_asc",
  user_id: "9334451938077",
  section_id: "section-1",
  ids: ["a", "b"],
});

const initial = (): Omit<State, "offset"> => ({ params: sectionParams(), results });

// Every click here is a fresh `set-params` dispatch with the same content — what any source that
// re-issues the current search produces, and what the loop that saturates the edge looks like.
const Harness = () => {
  const [state, dispatch] = useSearchReducer(initial());
  return (
    <>
      <button onClick={() => dispatch({ type: "set-params", params: { ...state.params } })}>same params</button>
      <button onClick={() => dispatch({ type: "set-params", params: { ...state.params, sort: "newest" } })}>
        other params
      </button>
      <CardGrid state={state} dispatchAction={dispatch} currencyCode="usd" />
    </>
  );
};

const failing = (error: Error) =>
  getSearchResults.mockReturnValue({ response: Promise.reject(error), cancel: () => {} });

describe("CardGrid search backoff", () => {
  it("does not re-ask for params the server rate limited, and tells the user why", async () => {
    failing(new RateLimitError("You're making requests too quickly. Please wait a moment and try again.", 900));
    render(<Harness />);

    fireEvent.click(screen.getByText("same params"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));
    // The server explained the wait; a generic "something went wrong" sends people looking for a
    // fault in their account that isn't there.
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(expect.stringContaining("too quickly"), "error"));

    fireEvent.click(screen.getByText("same params"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(getSearchResults).toHaveBeenCalledTimes(1);

    // A different search is a person, not a loop: it still goes through.
    fireEvent.click(screen.getByText("other params"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(2));
  });

  it("shares one request when the same params are asked for again while it is in flight", async () => {
    getSearchResults.mockReturnValue({ response: new Promise(() => {}), cancel: () => {} });
    render(<Harness />);

    fireEvent.click(screen.getByText("same params"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));

    // A slow answer is when a repeat costs the most: the second ask needs no second request.
    fireEvent.click(screen.getByText("same params"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(getSearchResults).toHaveBeenCalledTimes(1);
  });

  it("backs off when the response isn't our API's JSON, like an edge block page", async () => {
    failing(new SyntaxError("Unexpected token '<', \"<html>\"... is not valid JSON"));
    render(<Harness />);

    fireEvent.click(screen.getByText("same params"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(showAlert).toHaveBeenCalled());

    fireEvent.click(screen.getByText("same params"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(getSearchResults).toHaveBeenCalledTimes(1);
  });
});
