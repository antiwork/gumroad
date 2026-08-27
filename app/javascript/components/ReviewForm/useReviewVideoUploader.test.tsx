// @vitest-environment happy-dom

import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { getReviewVideoUploadContext } from "$app/data/product_reviews";

import { useReviewVideoUploader } from "$app/components/ReviewForm/useReviewVideoUploader";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("$vendor/evaporate.cjs", () => ({ default: vi.fn() }));

vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ external_id: "user-id" }),
}));

vi.mock("$app/data/product_reviews", () => ({
  getReviewVideoUploadContext: vi.fn(),
}));

const mockGetReviewVideoUploadContext = vi.mocked(getReviewVideoUploadContext);

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("useReviewVideoUploader", () => {
  it("does not request upload context while rendering a preview-only review form", async () => {
    const { result } = renderHook(() => useReviewVideoUploader({ preview: true }));

    expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    expect(result.current.error).toBeNull();
    expect(result.current.readyToUpload).toBe(false);
    expect(result.current.evaporateUploader).toBeNull();
    expect(result.current.s3UploadConfig).toBeNull();
  });

  it("requests upload context for an editable review form", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValueOnce({
      aws_access_key_id: "key",
      s3_url: "https://s3.example.com/bucket",
      user_id: "user-id",
    });

    const { result } = renderHook(() => useReviewVideoUploader({ preview: false }));

    await waitFor(() => expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce());
    expect(result.current.error).toBeNull();
  });
});
