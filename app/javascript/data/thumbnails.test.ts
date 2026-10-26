import { beforeEach, describe, expect, it, vi } from "vitest";

import { createThumbnail } from "$app/data/thumbnails";
import { cast } from "$app/utils/cast";
import { request, ResponseError } from "$app/utils/request";

vi.mock("$app/utils/request", async () => {
  const actual = await vi.importActual<typeof import("$app/utils/request")>("$app/utils/request");
  return { ...actual, request: vi.fn() };
});

vi.stubGlobal("Routes", new Proxy({}, { get: (_target, name: string) => () => `/${name}` }));

const replyWith = (status: number, body: unknown) =>
  vi.mocked(request).mockResolvedValue(
    cast<Response>({
      ok: status >= 200 && status < 300,
      status,
      json: () => (body === undefined ? Promise.reject(new Error("no body")) : Promise.resolve(body)),
    }),
  );

beforeEach(() => {
  vi.mocked(request).mockReset();
});

describe("createThumbnail", () => {
  it("returns the thumbnail the server saved", async () => {
    replyWith(200, { success: true, thumbnail: { guid: "thumb-1", url: "https://cdn.example.com/thumb.png" } });

    await expect(createThumbnail("abc", { type: "file", signedBlobId: "signed-1" })).resolves.toEqual({
      guid: "thumb-1",
      url: "https://cdn.example.com/thumb.png",
    });
  });

  it("surfaces the server's reason when the thumbnail is rejected", async () => {
    replyWith(200, {
      success: false,
      error: "Thumbnail processing took too long, please try again with a smaller image.",
    });

    await expect(createThumbnail("abc", { type: "file", signedBlobId: "signed-1" })).rejects.toThrow(
      "Thumbnail processing took too long, please try again with a smaller image.",
    );
  });

  it("surfaces the body's reason when the request itself fails", async () => {
    replyWith(400, { success: false, error: "Invalid signed_blob_id." });

    await expect(createThumbnail("abc", { type: "file", signedBlobId: "stale" })).rejects.toThrow(
      "Invalid signed_blob_id.",
    );
  });

  it("falls back to the generic message when there is no body to read", async () => {
    replyWith(500, undefined);

    const error = await createThumbnail("abc", { type: "file", signedBlobId: "signed-1" }).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ResponseError);
    if (!(error instanceof ResponseError)) throw new Error("Expected a ResponseError");
    expect(error.message).toBe("Something went wrong.");
  });
});
