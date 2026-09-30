// @vitest-environment happy-dom

import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { getReviewVideoUploadContext } from "$app/data/product_reviews";
import { ResponseError } from "$app/utils/request";

import { useReviewVideoUploader } from "$app/components/ReviewForm/useReviewVideoUploader";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("$vendor/evaporate.cjs", () => ({ default: vi.fn() }));

const mocks = vi.hoisted(() => {
  const state: { loggedInUser: { id: string } | null } = { loggedInUser: { id: "user-id" } };
  return state;
});

vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => mocks.loggedInUser }));

vi.mock("$app/data/product_reviews", () => ({
  getReviewVideoUploadContext: vi.fn(),
}));

const mockGetReviewVideoUploadContext = vi.mocked(getReviewVideoUploadContext);

const uploadContext = { aws_access_key_id: "key", s3_url: "https://s3.example.com/bucket", user_id: "user-id" };

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  mocks.loggedInUser = { id: "user-id" };
});

describe("useReviewVideoUploader", () => {
  it("does not request upload context while rendering a preview-only review form", () => {
    const { result } = renderHook(() => useReviewVideoUploader({ enabled: true, preview: true }));

    expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    expect(result.current.error).toBeNull();
    expect(result.current.readyToUpload).toBe(false);
    expect(result.current.evaporateUploader).toBeNull();
    expect(result.current.s3UploadConfig).toBeNull();
  });

  it("does not request upload context until it is enabled", () => {
    const { result } = renderHook(() => useReviewVideoUploader({ enabled: false }));

    expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    expect(result.current.readyToUpload).toBe(false);
    expect(result.current.evaporateUploader).toBeNull();
  });

  it("does not request upload context for a logged-out visitor", () => {
    mocks.loggedInUser = null;

    const { result } = renderHook(() => useReviewVideoUploader({ enabled: true }));

    expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    expect(result.current.readyToUpload).toBe(false);
  });

  it("requests upload context for an editable review form", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);

    const { result } = renderHook(() => useReviewVideoUploader({ enabled: true, preview: false }));

    await waitFor(() => expect(result.current.readyToUpload).toBe(true));
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce();
    expect(result.current.error).toBeNull();
    expect(result.current.evaporateUploader).not.toBeNull();
    expect(result.current.s3UploadConfig).not.toBeNull();
  });

  it("requests upload context when it becomes enabled after mounting", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);

    const { result, rerender } = renderHook(({ enabled }) => useReviewVideoUploader({ enabled }), {
      initialProps: { enabled: false },
    });
    expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();

    rerender({ enabled: true });

    await waitFor(() => expect(result.current.readyToUpload).toBe(true));
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce();
  });

  it("keeps the loaded upload context when it is disabled again and enabled later", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);
    const { result, rerender } = renderHook(({ enabled }) => useReviewVideoUploader({ enabled }), {
      initialProps: { enabled: true },
    });
    await waitFor(() => expect(result.current.readyToUpload).toBe(true));

    rerender({ enabled: false });
    rerender({ enabled: true });

    expect(result.current.readyToUpload).toBe(true);
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce();
  });

  it("does not request upload context again when the logged-in user object changes but not its id", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);
    const { result, rerender } = renderHook(() => useReviewVideoUploader({ enabled: true }));
    await waitFor(() => expect(result.current.readyToUpload).toBe(true));

    // A layout parses a fresh logged-in user object on every render, e.g. on each page poll.
    for (let render = 0; render < 5; render++) {
      mocks.loggedInUser = { id: "user-id" };
      rerender();
    }

    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce();
  });

  it("requests upload context for the new user when the logged-in user changes", async () => {
    mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
    const { result, rerender } = renderHook(() => useReviewVideoUploader({ enabled: true }));
    await waitFor(() => expect(result.current.readyToUpload).toBe(true));

    mocks.loggedInUser = { id: "other-user-id" };
    rerender();

    expect(result.current.readyToUpload).toBe(false);
    await waitFor(() => expect(result.current.readyToUpload).toBe(true));
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(2);
  });

  it("ignores a failure that arrives after it was disabled", async () => {
    let rejectRequest: (reason: ResponseError) => void = () => {};
    mockGetReviewVideoUploadContext.mockReturnValueOnce(
      new Promise((_resolve, reject) => {
        rejectRequest = reject;
      }),
    );
    const { result, rerender } = renderHook(({ enabled }) => useReviewVideoUploader({ enabled }), {
      initialProps: { enabled: true },
    });
    await waitFor(() => expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce());

    rerender({ enabled: false });
    await act(async () => {
      rejectRequest(new ResponseError());
      await Promise.resolve();
    });

    expect(result.current.error).toBeNull();
  });

  it("reports a failure without retrying on later renders, then retries once re-enabled and clears the failure", async () => {
    mockGetReviewVideoUploadContext.mockRejectedValueOnce(new ResponseError());
    mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);
    const { result, rerender } = renderHook(({ enabled }) => useReviewVideoUploader({ enabled }), {
      initialProps: { enabled: true },
    });
    await waitFor(() => expect(result.current.error).toBe("Failed to get upload context"));

    for (let render = 0; render < 5; render++) {
      mocks.loggedInUser = { id: "user-id" };
      rerender({ enabled: true });
    }
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledOnce();
    expect(result.current.readyToUpload).toBe(false);

    rerender({ enabled: false });
    rerender({ enabled: true });

    await waitFor(() => expect(result.current.readyToUpload).toBe(true));
    expect(result.current.error).toBeNull();
    expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(2);
  });
});
