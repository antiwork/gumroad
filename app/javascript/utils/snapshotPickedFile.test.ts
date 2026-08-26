import { describe, expect, it } from "vitest";

import {
  canResetFileInputAfterSnapshot,
  PICKED_FILE_SNAPSHOT_LIMIT_BYTES,
  snapshotPickedFile,
  snapshotPickedFiles,
} from "$app/utils/snapshotPickedFile";

describe("snapshotPickedFile", () => {
  it("copies a small file into an independent File with the same bytes and metadata", async () => {
    const original = new File(["pdf-bytes"], "guide.pdf", { type: "application/pdf", lastModified: 1_700_000_000_000 });

    const copy = await snapshotPickedFile(original);

    expect(copy).not.toBe(original);
    expect(copy.name).toBe("guide.pdf");
    expect(copy.type).toBe("application/pdf");
    expect(copy.size).toBe(original.size);
    expect(copy.lastModified).toBe(original.lastModified);
    expect(await copy.text()).toBe("pdf-bytes");
  });

  it("returns the same object for files over the copy limit so we do not buffer gigabyte uploads", async () => {
    const original = new File(["x"], "huge.mp4", { type: "video/mp4" });
    Object.defineProperty(original, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });

    const result = await snapshotPickedFile(original);

    expect(result).toBe(original);
  });
});

describe("canResetFileInputAfterSnapshot", () => {
  it("is false when any picked file was too large to copy", () => {
    const small = new File(["ok"], "a.pdf");
    const large = new File(["x"], "b.mp4");
    Object.defineProperty(large, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });

    expect(canResetFileInputAfterSnapshot([small])).toBe(true);
    expect(canResetFileInputAfterSnapshot([small, large])).toBe(false);
  });
});

describe("snapshotPickedFiles", () => {
  it("snapshots every file in the pick", async () => {
    const files = [new File(["a"], "a.txt"), new File(["b"], "b.txt")];

    const copies = await snapshotPickedFiles(files);

    expect(copies).toHaveLength(2);
    expect(copies[0]).not.toBe(files[0]);
    expect(await copies[0]?.text()).toBe("a");
    expect(await copies[1]?.text()).toBe("b");
  });
});
