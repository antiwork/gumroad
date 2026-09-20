// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { SearchResults } from "$app/data/search";
import { RateLimitError, ResponseError } from "$app/utils/request";

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

// One section of one profile, including the `ids` a storefront products section sends.
const sectionParams = () => ({
  sort: "price_asc",
  user_id: "9334451938077",
  section_id: "section-1",
  ids: ["a", "b"],
});

const initial = (): Omit<State, "offset"> => ({ params: sectionParams(), results });

// Every click is a fresh `set-params` dispatch: what any source that re-issues the current search
// produces, and the shape of the repeat that saturates the rate limit.
const Harness = () => {
  const [state, dispatch] = useSearchReducer(initial());
  const search = (sort: string) => () => dispatch({ type: "set-params", params: { ...state.params, sort } });
  return (
    <>
      <button onClick={search("price_asc")}>search A</button>
      <button onClick={search("newest")}>search B</button>
      <CardGrid state={state} dispatchAction={dispatch} currencyCode="usd" />
    </>
  );
};

const failing = (error: Error) =>
  getSearchResults.mockReturnValue({ response: Promise.reject(error), cancel: () => {} });

const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

describe("CardGrid search backoff", () => {
  it("does not re-ask for params the server rate limited, and tells the user why", async () => {
    const report = vi.spyOn(console, "error").mockImplementation(() => {});
    failing(new RateLimitError("You're making requests too quickly. Please wait a moment and try again.", 900));
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));
    // The server knows what the wait is; a generic "something went wrong" sends people looking for a
    // fault in their account that isn't there.
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(expect.stringContaining("too quickly"), "error"));
    expect(report).not.toHaveBeenCalled();
    report.mockRestore();

    fireEvent.click(screen.getByText("search A"));
    await settle();
    expect(getSearchResults).toHaveBeenCalledTimes(1);

    // A different search is a person, not a loop: it still goes through.
    fireEvent.click(screen.getByText("search B"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(2));
  });

  it("does not report a handled API error that is not a rate limit", async () => {
    const report = vi.spyOn(console, "error").mockImplementation(() => {});
    failing(new ResponseError("Something went wrong."));
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(showAlert).toHaveBeenCalled());
    expect(report).not.toHaveBeenCalled();
    report.mockRestore();
  });

  it("keeps each failed search's cooldown when a second one fails in the same window", async () => {
    failing(new RateLimitError("You're making requests too quickly. Please wait a moment and try again.", 900));
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByText("search B"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(2));

    // Back to the first search: its own window is still open, so it must not be asked again.
    fireEvent.click(screen.getByText("search A"));
    await settle();
    expect(getSearchResults).toHaveBeenCalledTimes(2);
  });

  it("shares one request when the same params are asked for again while it is in flight", async () => {
    getSearchResults.mockReturnValue({ response: new Promise(() => {}), cancel: () => {} });
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));

    // A slow answer is when a repeat costs the most: the second ask needs no second request.
    fireEvent.click(screen.getByText("search A"));
    await settle();
    expect(getSearchResults).toHaveBeenCalledTimes(1);
  });

  it("serves a repeat of a search that is still in flight from that request's answer", async () => {
    let resolveRequest: (value: SearchResults) => void = () => {};
    getSearchResults.mockReturnValue({
      response: new Promise<SearchResults>((resolve) => {
        resolveRequest = resolve;
      }),
      cancel: () => {},
    });
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));

    // Nothing cancels a search request, so a repeat while it is still out is answered by it: the
    // grid still gets results rather than being left mid-search with nothing in flight.
    fireEvent.click(screen.getByText("search A"));
    await settle();
    expect(getSearchResults).toHaveBeenCalledTimes(1);

    resolveRequest(results);
    await waitFor(() => expect(screen.getByText("No products found")).toBeTruthy());
  });

  it("backs off when the response isn't our API's JSON, like an edge block page", async () => {
    const report = vi.spyOn(console, "error").mockImplementation(() => {});
    failing(new SyntaxError("Unexpected token '<', \"<html>\"... is not valid JSON"));
    render(<Harness />);

    fireEvent.click(screen.getByText("search A"));
    await waitFor(() => expect(getSearchResults).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(showAlert).toHaveBeenCalled());
    expect(report).toHaveBeenCalled();

    fireEvent.click(screen.getByText("search A"));
    await settle();
    expect(getSearchResults).toHaveBeenCalledTimes(1);
  });
});
