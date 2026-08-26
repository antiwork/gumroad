// @vitest-environment happy-dom
import { renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";

import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";

const evaporate = vi.hoisted(() => ({ add: vi.fn(), cancel: vi.fn() }));
const Evaporate = vi.hoisted(() =>
  // `new Evaporate()` must be constructable and return the shared spies.
  // eslint-disable-next-line prefer-arrow-callback
  vi.fn(function Evaporate() {
    return evaporate;
  }),
);

vi.mock("$vendor/evaporate.cjs", () => ({ default: Evaporate }));

vi.stubGlobal(
  "Routes",
  new Proxy(
    {},
    {
      get: () => () => "#",
    },
  ),
);

afterEach(() => {
  evaporate.add.mockReset();
  evaporate.cancel.mockReset();
  Evaporate.mockClear();
});

it("cancels Evaporate's first queued file when its id is 0", () => {
  evaporate.add.mockImplementation((params: { initiated: (id: number) => void }) => {
    // Vendor addFile uses files.length, so the first queued file is numeric 0.
    params.initiated(0);
    return 0;
  });

  const { result } = renderHook(() =>
    useConfigureEvaporate({
      aws_access_key_id: "key",
      s3_url: "https://s3.amazonaws.com/bucket",
      user_id: "user-1",
    }),
  );

  result.current.evaporateUploader.scheduleUpload({
    cancellationKey: "file_abc",
    name: "key",
    file: new File(["x"], "notes.txt", { type: "text/plain" }),
    mimeType: "text/plain",
    onComplete: () => {},
    onProgress: () => {},
  });
  result.current.evaporateUploader.cancelUpload("file_abc");

  expect(evaporate.cancel).toHaveBeenCalledWith(0);
});
