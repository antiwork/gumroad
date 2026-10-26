// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { getStreamingUrls } from "$app/data/product_reviews";
import { createJWPlayer } from "$app/utils/jwPlayer";

import { ReviewVideoPlayer } from "$app/components/ReviewVideoPlayer";
import { showAlert } from "$app/components/server-components/Alert";

vi.mock("$app/data/product_reviews", () => ({ getStreamingUrls: vi.fn() }));
vi.mock("$app/utils/jwPlayer", () => ({ createJWPlayer: vi.fn() }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/PlayVideoIcon", () => ({ PlayVideoIcon: () => null }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

it("restores Watch after a streaming request fails and permits retry", async () => {
  vi.mocked(getStreamingUrls).mockRejectedValueOnce(new Error("Offline"));
  render(<ReviewVideoPlayer videoId="video-1" />);
  fireEvent.click(screen.getByRole("button", { name: "Watch" }));
  await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Could not load the video. Please try again.", "error"));
  expect(screen.getByRole<HTMLButtonElement>("button", { name: "Watch" }).disabled).toBe(false);

  vi.mocked(getStreamingUrls).mockRejectedValueOnce(new Error("Still offline"));
  fireEvent.click(screen.getByRole("button", { name: "Watch" }));
  await waitFor(() => expect(getStreamingUrls).toHaveBeenCalledTimes(2));
});

it("also recovers if the player cannot initialize", async () => {
  vi.mocked(getStreamingUrls).mockResolvedValue({ streaming_urls: ["https://example.com/video.m3u8"] });
  vi.mocked(createJWPlayer).mockRejectedValue(new Error("Script unavailable"));
  render(<ReviewVideoPlayer videoId="video-1" />);
  await act(async () => {
    fireEvent.click(screen.getByRole("button", { name: "Watch" }));
  });
  expect(showAlert).toHaveBeenCalledOnce();
  expect(screen.getByRole<HTMLButtonElement>("button", { name: "Watch" }).disabled).toBe(false);
});

it("does not create a player when the streaming response arrives after unmount", async () => {
  let finish!: (value: Awaited<ReturnType<typeof getStreamingUrls>>) => void;
  vi.mocked(getStreamingUrls).mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const { unmount } = render(<ReviewVideoPlayer videoId="video-1" />);
  fireEvent.click(screen.getByRole("button", { name: "Watch" }));
  unmount();
  await act(async () => {
    finish({ streaming_urls: ["https://example.com/video.m3u8"] });
  });
  expect(createJWPlayer).not.toHaveBeenCalled();
  expect(showAlert).not.toHaveBeenCalled();
});

it("does not show a stale error after unmount", async () => {
  let fail!: (reason: Error) => void;
  vi.mocked(getStreamingUrls).mockImplementationOnce(
    () =>
      new Promise((_resolve, reject) => {
        fail = reject;
      }),
  );
  const { unmount } = render(<ReviewVideoPlayer videoId="video-1" />);
  fireEvent.click(screen.getByRole("button", { name: "Watch" }));
  unmount();
  await act(async () => {
    fail(new Error("Offline"));
  });
  expect(showAlert).not.toHaveBeenCalled();
});
