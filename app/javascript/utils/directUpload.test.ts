import { beforeEach, describe, expect, it, vi } from "vitest";

import { uploadErrorMessage, uploadFileWithRetry } from "$app/utils/directUpload";

type UploadCallback = (error: unknown, blob?: { signed_id: string }) => void;
const uploads = vi.hoisted((): { callbacks: UploadCallback[] } => ({ callbacks: [] }));

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: UploadCallback) {
      uploads.callbacks.push(callback);
    }
  },
}));

beforeEach(() => {
  uploads.callbacks.length = 0;
});

describe("uploadFileWithRetry", () => {
  it("retries once and returns the blob of the attempt that succeeded", async () => {
    const uploaded = uploadFileWithRetry(new File(["pixels"], "cover.png"), "/rails/active_storage/direct_uploads");

    await vi.waitFor(() => expect(uploads.callbacks).toHaveLength(1));
    uploads.callbacks[0]?.('Error storing "cover.png". Status: 0');

    await vi.waitFor(() => expect(uploads.callbacks).toHaveLength(2));
    uploads.callbacks[1]?.(null, { signed_id: "signed-1" });

    await expect(uploaded).resolves.toEqual({ signed_id: "signed-1" });
  });

  it("gives up with the last error once every attempt failed", async () => {
    const uploaded = uploadFileWithRetry(new File(["pixels"], "cover.png"), "/rails/active_storage/direct_uploads");

    await vi.waitFor(() => expect(uploads.callbacks).toHaveLength(1));
    uploads.callbacks[0]?.('Error storing "cover.png". Status: 0');

    await vi.waitFor(() => expect(uploads.callbacks).toHaveLength(2));
    uploads.callbacks[1]?.('Error storing "cover.png". Status: 500');

    await expect(uploaded).rejects.toBe('Error storing "cover.png". Status: 500');
    expect(uploads.callbacks).toHaveLength(2);
  });

  it("uploads only once when one attempt is asked for", async () => {
    const uploaded = uploadFileWithRetry(new File(["pixels"], "cover.png"), "/rails/active_storage/direct_uploads", 1);

    await vi.waitFor(() => expect(uploads.callbacks).toHaveLength(1));
    uploads.callbacks[0]?.("nope");

    await expect(uploaded).rejects.toBe("nope");
    expect(uploads.callbacks).toHaveLength(1);
  });
});

describe("uploadErrorMessage", () => {
  it.each([
    ['Error storing "cover.png". Status: 0', 'Error storing "cover.png". Status: 0'],
    [new Error("Upload failed"), "Upload failed"],
    ["", "Could not upload your image. Please try again."],
    [new Error(), "Could not upload your image. Please try again."],
    [undefined, "Could not upload your image. Please try again."],
  ])("reads %s as %s", (error, expected) => {
    expect(uploadErrorMessage(error)).toBe(expected);
  });
});
