// @vitest-environment happy-dom
import { renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";

import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";

vi.stubGlobal(
  "Routes",
  new Proxy(
    {},
    {
      get: () => () => "https://example.test/sign",
    },
  ),
);

class FakeXHR {
  static queue: Array<{ status: number; response: string }> = [];

  status = 0;
  readyState = 0;
  response = "";
  responseText = "";
  onreadystatechange: (() => void) | null = null;
  onerror: (() => void) | null = null;
  upload = { onprogress: null as ((evt: ProgressEvent) => void) | null };

  open() {}
  setRequestHeader() {}
  abort() {}
  getResponseHeader() {
    return null;
  }
  send() {
    const next = FakeXHR.queue.shift() ?? { status: 500, response: "" };
    this.status = next.status;
    this.response = next.response;
    this.responseText = next.response;
    this.readyState = 4;
    this.onreadystatechange?.();
  }
}

const OriginalXHR = globalThis.XMLHttpRequest;

afterEach(() => {
  FakeXHR.queue = [];
  globalThis.XMLHttpRequest = OriginalXHR;
});

it("forwards an S3 multipart initiate failure to onError", async () => {
  // Time lookup, signer (exactly 28 chars), then a failed initiate POST.
  FakeXHR.queue = [
    { status: 200, response: "Wed, 26 Aug 2026 00:00:00 GMT" },
    { status: 200, response: "1234567890123456789012345678" },
    { status: 403, response: "AccessDenied" },
  ];
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- test double implements the XHR methods Evaporate uses
  globalThis.XMLHttpRequest = FakeXHR as unknown as typeof XMLHttpRequest;

  const onError = vi.fn();
  const { result } = renderHook(() =>
    useConfigureEvaporate({
      aws_access_key_id: "key",
      s3_url: "https://s3.amazonaws.com/bucket",
      user_id: "user-1",
    }),
  );

  result.current.evaporateUploader.scheduleUpload({
    cancellationKey: "subtitles_for_file",
    name: "key",
    file: new File(["x"], "huge.srt", { type: "text/plain" }),
    mimeType: "text/plain",
    onComplete: () => {},
    onProgress: () => {},
    onError,
  });

  await vi.waitFor(() => {
    expect(onError).toHaveBeenCalled();
  });
});
