// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PICKED_FILE_SNAPSHOT_LIMIT_BYTES } from "$app/utils/snapshotPickedFile";

import { SubtitleUploadBox } from "$app/components/SubtitleUploadBox";

const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

afterEach(() => {
  cleanup();
  alerts.length = 0;
});

const attachPickedFile = (input: HTMLInputElement, picked: File) => {
  const valueWrites: string[] = [];
  Object.defineProperty(input, "files", {
    configurable: true,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- minimal FileList for the handler
    value: {
      length: 1,
      item: (index: number) => (index === 0 ? picked : null),
      [Symbol.iterator]: () => [picked][Symbol.iterator](),
    } as unknown as FileList,
  });
  Object.defineProperty(input, "value", {
    configurable: true,
    get: () => "",
    set: (value: string) => valueWrites.push(value),
  });
  return valueWrites;
};

const renderPicker = () => {
  const onUploadFiles = vi.fn<(files: File[]) => void>();
  render(<SubtitleUploadBox onUploadFiles={onUploadFiles} />);
  const input = document.querySelector<HTMLInputElement>("input.subtitles-file");
  if (!input) throw new Error("Subtitle file input did not mount");
  return { onUploadFiles, input };
};

describe("SubtitleUploadBox", () => {
  it("uploads a snapshot copy of a small subtitle and resets the input", async () => {
    const { onUploadFiles, input } = renderPicker();
    const picked = new File(["1\n00:00:00,000 --> 00:00:01,000\nhi\n"], "captions.srt", { type: "text/plain" });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      // snapshotPickedFiles settles on a microtask after the change handler returns
      await Promise.resolve();
    });

    const [uploaded] = onUploadFiles.mock.calls[0]?.[0] ?? [];
    if (!uploaded) throw new Error("onUploadFiles was not called");
    // A copy must be handed off, not the picked File: resetting the input revokes the
    // original's backing in Chromium, stranding the upload at 0%.
    expect(uploaded).not.toBe(picked);
    expect(uploaded.name).toBe("captions.srt");
    expect(uploaded.size).toBe(picked.size);
    expect(await uploaded.text()).toBe(await picked.text());
    expect(valueWrites).toEqual([""]);
  });

  it("keeps the original handle and leaves the input alone for an over-budget subtitle", async () => {
    const { onUploadFiles, input } = renderPicker();
    const picked = new File(["x"], "huge.srt", { type: "text/plain" });
    Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      // snapshotPickedFiles settles on a microtask after the change handler returns
      await Promise.resolve();
    });

    expect(onUploadFiles.mock.calls[0]?.[0]).toEqual([picked]);
    expect(valueWrites).toEqual([]);
  });

  it("rejects a file that is not a subtitle before snapshotting it", async () => {
    const { onUploadFiles, input } = renderPicker();
    const picked = new File(["notes"], "notes.txt", { type: "text/plain" });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      // snapshotPickedFiles settles on a microtask after the change handler returns
      await Promise.resolve();
    });

    expect(alerts).toEqual([{ message: "Invalid file type.", level: "error" }]);
    expect(onUploadFiles).not.toHaveBeenCalled();
    expect(valueWrites).toEqual([]);
  });

  it("ignores a second pick while the first snapshot is still in flight", async () => {
    const { onUploadFiles, input } = renderPicker();
    let releaseFirst!: () => void;
    const firstReady = new Promise<ArrayBuffer>((resolve) => {
      releaseFirst = () => resolve(new TextEncoder().encode("first").buffer);
    });
    const first = new File(["first"], "first.srt", { type: "text/plain" });
    Object.defineProperty(first, "arrayBuffer", { value: () => firstReady });
    const second = new File(["second"], "second.srt", { type: "text/plain" });

    attachPickedFile(input, first);
    act(() => {
      fireEvent.change(input);
    });

    attachPickedFile(input, second);
    act(() => {
      fireEvent.change(input);
    });

    await act(async () => {
      releaseFirst();
      await firstReady;
      await Promise.resolve();
    });

    expect(onUploadFiles).toHaveBeenCalledTimes(1);
    expect(onUploadFiles.mock.calls[0]?.[0][0]?.name).toBe("first.srt");
  });

  it("holds an over-budget input until the upload promise settles, then resets", async () => {
    let releaseUpload!: () => void;
    const uploadDone = new Promise<void>((resolve) => {
      releaseUpload = resolve;
    });
    const onUploadFiles = vi.fn<(files: File[]) => Promise<void>>(() => uploadDone);
    render(<SubtitleUploadBox onUploadFiles={onUploadFiles} />);
    const input = document.querySelector<HTMLInputElement>("input.subtitles-file");
    if (!input) throw new Error("Subtitle file input did not mount");
    const picked = new File(["x"], "huge.srt", { type: "text/plain" });
    Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
    const valueWrites = attachPickedFile(input, picked);

    await act(async () => {
      fireEvent.change(input);
      await Promise.resolve();
    });

    expect(onUploadFiles.mock.calls[0]?.[0]).toEqual([picked]);
    expect(valueWrites).toEqual([]);
    expect(input.disabled).toBe(true);

    act(() => {
      fireEvent.change(input);
    });
    expect(onUploadFiles).toHaveBeenCalledTimes(1);

    await act(async () => {
      releaseUpload();
      await uploadDone;
      await Promise.resolve();
    });

    expect(valueWrites).toEqual([""]);
    expect(input.disabled).toBe(false);
  });
});
