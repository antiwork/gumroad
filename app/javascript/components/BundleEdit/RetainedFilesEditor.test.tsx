// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { RetainedFile, RetainedFilesEditor } from "$app/components/BundleEdit/RetainedFilesEditor";
import { showAlert } from "$app/components/server-components/Alert";

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

const UNCONFIRMED = "We couldn't confirm the file was removed. Refresh the page to check.";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const htmlResponse = (status: number) =>
  new Response("<!DOCTYPE html><html><body>Not found</body></html>", {
    status,
    headers: { "Content-Type": "text/html" },
  });

const renderEditor = (files: RetainedFile[]) =>
  render(<RetainedFilesEditor bundleId="bundle-id" files={files} onRemoved={onRemoved} />);

const secondFile: RetainedFile = { id: "file-2", name: "vol-2.pdf", filetype: "pdf", size: "2 MB" };

// Mirrors the bundle editor, which drops the removed file from the list it passes back in.
const Harness = ({ initialFiles }: { initialFiles: RetainedFile[] }) => {
  const [files, setFiles] = React.useState(initialFiles);
  return (
    <RetainedFilesEditor
      bundleId="bundle-id"
      files={files}
      onRemoved={(id) => setFiles((current) => current.filter((file) => file.id !== id))}
    />
  );
};

describe("RetainedFilesEditor", () => {
  let fetchMock: ReturnType<typeof vi.fn<typeof fetch>>;

  const removeFile = async () => {
    fireEvent.click(screen.getByRole("button", { name: "Remove vol-1.zip" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
  };

  beforeEach(() => {
    vi.resetAllMocks();
    vi.stubGlobal("Routes", {
      remove_file_bundle_product_path: (id: string) => `/bundles/${id}/product/remove_file`,
    });
    fetchMock = vi.fn<typeof fetch>(() => Promise.resolve(jsonResponse({ success: true })));
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("lists the bundle's own files with their type and size", () => {
    renderEditor([retainedFile]);

    expect(screen.getByText("vol-1.zip")).toBeDefined();
    expect(screen.getByText("ZIP · 139 MB")).toBeDefined();
  });

  it("removes the file the seller confirmed, and only that file", async () => {
    renderEditor([retainedFile]);

    await removeFile();

    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe("/bundles/bundle-id/product/remove_file");
    expect(init?.method).toBe("POST");
    expect(init?.body).toBe(JSON.stringify({ file_id: "file-1" }));
    expect(new Headers(init?.headers).get("Accept")).toContain("application/json");
    await waitFor(() => expect(onRemoved).toHaveBeenCalledWith("file-1"));
    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("Removed vol-1.zip."));
    expect(showAlert).not.toHaveBeenCalled();
  });

  it("confirms a removal inside the Files section until the seller dismisses it", async () => {
    render(<Harness initialFiles={[retainedFile, secondFile]} />);

    await removeFile();

    const section = screen.getByRole("heading", { name: "Files" }).closest("section");
    if (!section) throw new Error("no Files section");
    const status = within(section).getByRole("status");
    await waitFor(() => expect(status.textContent).toBe("Removed vol-1.zip."));
    expect(within(section).queryByRole("button", { name: "Remove vol-1.zip" })).toBeNull();
    expect(within(section).getByRole("button", { name: "Remove vol-2.pdf" })).toBeDefined();
    expect(showAlert).not.toHaveBeenCalled();

    fireEvent.click(within(status).getByRole("button", { name: "Dismiss" }));

    expect(within(section).getByRole("status").textContent).toBe("");
  });

  it("announces the confirmation through a live region that was already on the page", async () => {
    render(<Harness initialFiles={[retainedFile, secondFile]} />);
    const region = screen.getByRole("status");
    expect(region.textContent).toBe("");

    await removeFile();

    await waitFor(() => expect(region.textContent).toBe("Removed vol-1.zip."));
    expect(screen.getByRole("status")).toBe(region);
  });

  it("keeps the confirmation on screen after the last file is removed", async () => {
    render(<Harness initialFiles={[retainedFile]} />);

    await removeFile();

    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("Removed vol-1.zip."));
    expect(screen.getByRole("heading", { name: "Files" })).toBeDefined();
    expect(screen.queryByRole("list")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));

    expect(screen.queryByRole("heading", { name: "Files" })).toBeNull();
  });

  it("drops an earlier confirmation when a later removal fails", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ success: true }))
      .mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Not yours" }, 422));
    render(<Harness initialFiles={[retainedFile, secondFile]} />);

    await removeFile();
    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("Removed vol-1.zip."));
    fireEvent.click(screen.getByRole("button", { name: "Remove vol-2.pdf" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Not yours", "error"));
    expect(screen.getByRole("status").textContent).toBe("");
    expect(screen.getByRole("button", { name: "Remove vol-2.pdf" })).toBeDefined();
  });

  it("lists each file as an item of the Files list with its own remove action", () => {
    renderEditor([retainedFile, secondFile]);

    const list = screen.getByRole("list", { name: "Files" });
    const items = within(list).getAllByRole("listitem");
    expect(items).toHaveLength(2);
    expect(within(items[0] ?? list).getByRole("button", { name: "Remove vol-1.zip" })).toBeDefined();
    expect(within(items[1] ?? list).getByRole("button", { name: "Remove vol-2.pdf" })).toBeDefined();
  });

  it("keeps the file when the server refuses", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: false, error_message: "Not yours" }, 422));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Not yours", "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("shows the role refusal when the seller's team role can't edit the bundle", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ success: false, error: "Your current role as Support cannot perform this action." }, 401),
    );
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() =>
      expect(showAlert).toHaveBeenCalledWith("Your current role as Support cannot perform this action.", "error"),
    );
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("doesn't claim the file was kept when an HTML error page hides the outcome", async () => {
    fetchMock.mockResolvedValueOnce(htmlResponse(404));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(UNCONFIRMED, "error"));
    expect(onRemoved).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.queryByRole("button", { name: "Remove" })).toBeNull());
  });

  it("does not report a removal for a successful response that doesn't confirm one", async () => {
    fetchMock.mockResolvedValueOnce(htmlResponse(200));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(UNCONFIRMED, "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("treats a server error as unconfirmed, since it can follow the committed deletion", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: false }, 500));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(UNCONFIRMED, "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("treats a lost connection as unconfirmed and doesn't resend the removal", async () => {
    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith(UNCONFIRMED, "error"));
    expect(onRemoved).not.toHaveBeenCalled();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("shows the rate limit's own message, which is refused before any write", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Slow down and try again in a minute." }, 429));
    renderEditor([retainedFile]);

    await removeFile();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Slow down and try again in a minute.", "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("renders nothing when the bundle has no files of its own", () => {
    renderEditor([]);

    expect(screen.queryByRole("heading", { name: "Files" })).toBeNull();
  });
});
