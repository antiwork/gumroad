// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { DisableDownloadsForAllFiles } from "$app/components/ProductEdit/ContentTab/DisableDownloadsForAllFiles";

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });
Object.assign(globalThis, {
  Routes: {
    disable_downloads_for_all_files_link_path: (permalink: string) =>
      `/links/${permalink}/disable_downloads_for_all_files`,
  },
});

// `updateProduct` hands the updater the editor's product, the way the real one does, so the
// assertions below read the state the editor would be left holding.
const state = vi.hoisted(() => ({
  requests: new Array<{ url: string; method?: string }>(),
  responses: new Array<unknown>(),
  results: new Array<{ message: string; status: string }>(),
  product: {
    files: new Array<{ id: string; stream_only: boolean }>(),
  },
}));

vi.mock("$app/utils/request", () => ({
  request: (settings: { url: string; method?: string }) => {
    state.requests.push(settings);
    return Promise.resolve({ ok: true, json: () => Promise.resolve(state.responses.shift()) });
  },
  ResponseError: class ResponseError extends Error {},
}));

vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({
    uniquePermalink: "demo",
    updateProduct: (update: (product: typeof state.product) => void) => update(state.product),
  }),
}));

beforeEach(() => {
  state.requests = [];
  state.responses = [];
  state.results = [];
  state.product = {
    files: [
      { id: "file-a", stream_only: false },
      { id: "file-b", stream_only: false },
      { id: "file-c", stream_only: false },
    ],
  };
});

afterEach(cleanup);

const onResult = (result: { message: string; status: string }) => state.results.push(result);

const openConfirmation = async () => {
  render(<DisableDownloadsForAllFiles onResult={onResult} />);
  fireEvent.click(screen.getByRole("button", { name: "Disable all downloads" }));
  return screen.findByRole("button", { name: "Yes, disable downloads" });
};

it("turns downloads off for the whole product and mirrors the changed files into the editor state", async () => {
  state.responses.push({
    success: true,
    disabled_count: 2,
    disabled_file_ids: ["file-a", "file-b"],
    already_disabled_count: 1,
    ineligible_count: 1,
  });

  fireEvent.click(await openConfirmation());

  await waitFor(() => expect(state.requests).toHaveLength(1));
  expect(state.requests[0]).toMatchObject({
    method: "POST",
    url: "/links/demo/disable_downloads_for_all_files",
  });

  // Exactly the files the server wrote, and only those: a later save re-sends this state.
  await waitFor(() =>
    expect(state.product.files).toEqual([
      { id: "file-a", stream_only: true },
      { id: "file-b", stream_only: true },
      { id: "file-c", stream_only: false },
    ]),
  );

  expect(state.results).toEqual([
    {
      message:
        "Downloads are now off for 2 files. 1 file stays downloadable, because the browser can't open it for your buyers.",
      status: "success",
    },
  ]);
});

it("says which files keep their download when some can't have it turned off", async () => {
  state.responses.push({
    success: true,
    disabled_count: 0,
    disabled_file_ids: [],
    already_disabled_count: 0,
    ineligible_count: 3,
  });

  fireEvent.click(await openConfirmation());

  await waitFor(() =>
    expect(state.results).toEqual([
      {
        message:
          "Every file that can have downloads off already does. 3 files stay downloadable, because the browser can't open them for your buyers.",
        status: "info",
      },
    ]),
  );
});

it("does not touch the product when the seller cancels the confirmation", async () => {
  await openConfirmation();
  fireEvent.click(screen.getByRole("button", { name: "No, cancel" }));

  await waitFor(() => expect(screen.queryByRole("button", { name: "Yes, disable downloads" })).toBeNull());
  expect(state.requests).toHaveLength(0);
  expect(state.product.files.every((file) => !file.stream_only)).toBe(true);
  expect(state.results).toEqual([]);
});
