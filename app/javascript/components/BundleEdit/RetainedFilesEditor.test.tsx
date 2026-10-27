// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { RetainedFile, RetainedFilesEditor } from "$app/components/BundleEdit/RetainedFilesEditor";
import { showAlert } from "$app/components/server-components/Alert";

Object.assign(globalThis, {
  Routes: { remove_file_bundle_product_path: (id: string) => `/bundles/${id}/product/remove_file` },
});

const state = vi.hoisted(() => ({
  requests: new Array<{ url: string; method?: string; data?: unknown }>(),
  responses: new Array<{ ok: boolean; body: unknown }>(),
}));

vi.mock("$app/utils/request", () => ({
  request: (settings: { url: string; method?: string; data?: unknown }) => {
    state.requests.push(settings);
    const next = state.responses.shift() ?? { ok: true, body: { success: true } };
    return Promise.resolve({ ok: next.ok, json: () => Promise.resolve(next.body) });
  },
  ResponseError: class ResponseError extends Error {},
  assertResponseError: (e: unknown) => {
    if (!(e instanceof Error)) throw e;
  },
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

// The confirmation is a radix portal; render it inline so the whole flow stays in the tested tree.
vi.mock("$app/components/Modal", () => ({
  Modal: ({ children, footer }: { children: React.ReactNode; footer?: React.ReactNode }) => (
    <div>
      {children}
      {footer}
    </div>
  ),
}));

const retainedFile: RetainedFile = {
  id: "file-1",
  name: "vol-1.zip",
  filetype: "zip",
  size: "139 MB",
};

const onRemoved = vi.fn();

const renderEditor = (files: RetainedFile[]) =>
  render(<RetainedFilesEditor bundleId="bundle-id" files={files} onRemoved={onRemoved} />);

const removeFile = async () => {
  fireEvent.click(screen.getByRole("button", { name: "Remove vol-1.zip" }));
  fireEvent.click(screen.getByRole("button", { name: "Remove" }));
  await waitFor(() => expect(state.requests).toHaveLength(1));
};

describe("RetainedFilesEditor", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    state.requests = [];
    state.responses = [];
  });
  afterEach(cleanup);

  it("lists the bundle's own files with their type and size", () => {
    renderEditor([retainedFile]);

    expect(screen.getByText("vol-1.zip")).toBeDefined();
    expect(screen.getByText("ZIP · 139 MB")).toBeDefined();
  });

  it("removes the file the seller confirmed, and only that file", async () => {
    renderEditor([retainedFile]);

    await removeFile();

    expect(state.requests[0]).toMatchObject({
      method: "POST",
      url: "/bundles/bundle-id/product/remove_file",
      data: { file_id: "file-1" },
    });
    await waitFor(() => expect(onRemoved).toHaveBeenCalledWith("file-1"));
    expect(showAlert).toHaveBeenCalledWith("File removed.", "success");
  });

  it("keeps the file when the server refuses", async () => {
    state.responses.push({ ok: false, body: { success: false, error_message: "Not yours" } });
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Not yours", "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("renders nothing when the bundle has no files of its own", () => {
    renderEditor([]);

    expect(screen.queryByRole("heading", { name: "Files" })).toBeNull();
  });
});
