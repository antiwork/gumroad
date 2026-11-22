// @vitest-environment happy-dom
//
// The share image uploads straight to storage through the profile picture's direct-upload helper and
// hands the save a signed blob id, so what it reports back is the whole contract the editor saves.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { ShareImageInput } from "$app/components/Pages/ShareImageInput";

vi.stubGlobal("Routes", {
  s3_utility_cdn_url_for_blob_path: ({ key }: { key: string }) => `https://cdn.example/${key}`,
});

const uploadFileWithRetry = vi.hoisted(() => vi.fn());
const uploadErrorMessage = vi.hoisted(() => vi.fn(() => "Upload failed."));
vi.mock("$app/utils/directUpload", () => ({ uploadFileWithRetry, uploadErrorMessage }));

const showAlert = vi.hoisted(() => vi.fn());
vi.mock("$app/components/server-components/Alert", () => ({ showAlert }));

const chooseFile = (container: HTMLElement, file: File) =>
  fireEvent.change(assertDefined(container.querySelector('input[type="file"]')), { target: { files: [file] } });

describe("ShareImageInput", () => {
  afterEach(() => {
    cleanup();
    uploadFileWithRetry.mockReset();
    showAlert.mockReset();
  });

  it("reports the uploaded blob's signed id and CDN URL", async () => {
    uploadFileWithRetry.mockResolvedValue({ key: "blob-key", signed_id: "signed-blob-id" });
    const onChange = vi.fn();
    const { container } = render(<ShareImageInput imageUrl={null} onChange={onChange} />);

    chooseFile(container, new File(["pixels"], "cover.png", { type: "image/png" }));

    await waitFor(() =>
      expect(onChange).toHaveBeenCalledWith({ signedId: "signed-blob-id", url: "https://cdn.example/blob-key" }),
    );
  });

  it("reports a removal for the Remove button", () => {
    const onChange = vi.fn();
    render(<ShareImageInput imageUrl="https://cdn.example/blob-key" onChange={onChange} />);

    fireEvent.click(screen.getByRole("button", { name: "Remove share image" }));

    expect(onChange).toHaveBeenCalledWith(null);
  });

  it("recommends 1024x536 and warns that preview apps may crop the image, some to a square", () => {
    render(<ShareImageInput imageUrl={null} onChange={vi.fn()} />);

    const help = screen.getByText(/Recommended size: 1024x536px \(1\.91:1\)\./u).textContent;
    expect(help).toContain(
      "Apps that show link previews may crop it, some to a square, so keep important content in the center.",
    );
  });

  it("leads with which shared links use the image and which don't", () => {
    render(<ShareImageInput imageUrl={null} onChange={vi.fn()} />);

    const help = screen.getByText(/Recommended size: 1024x536px/u).textContent;
    expect(help).toMatch(
      /^Shared links to your home page and other pages use this image\. Links to products, posts and wishlists don't\. JPG or PNG/u,
    );
  });

  it("refuses a file that is not a JPG or PNG without uploading it", async () => {
    const onChange = vi.fn();
    const { container } = render(<ShareImageInput imageUrl={null} onChange={onChange} />);

    chooseFile(container, new File(["frames"], "animation.gif", { type: "image/gif" }));

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Please choose a JPG or PNG image.", "error"));
    expect(uploadFileWithRetry).not.toHaveBeenCalled();
    expect(onChange).not.toHaveBeenCalled();
  });
});
