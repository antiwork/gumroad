// @vitest-environment happy-dom
import { renderHook } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { FileAction, FilesDispatchProvider, useUploadSubtitles } from "$app/components/EmailAttachments";

const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

const scheduledUploads = vi.hoisted((): { onComplete: () => void; onError?: () => void }[] => []);

vi.mock("$app/components/EvaporateUploader", () => ({
  useEvaporateUploader: () => ({
    scheduleUpload: (options: { onComplete: () => void; onError?: () => void }) => {
      scheduledUploads.push(options);
      return 0;
    },
    cancelUpload: () => {},
  }),
}));

vi.mock("$app/components/S3UploadConfig", () => ({
  useS3UploadConfig: () => ({
    generateS3KeyForUpload: (guid: string, name: string) => ({
      s3key: `key-${guid}`,
      fileUrl: `https://s3.example/${guid}/${name}`,
    }),
  }),
}));

afterEach(() => {
  scheduledUploads.length = 0;
  alerts.length = 0;
});

it("settles the subtitle upload promise when Evaporate errors", async () => {
  const dispatched: FileAction[] = [];
  const { result } = renderHook(() => useUploadSubtitles(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <FilesDispatchProvider value={(action) => dispatched.push(action)}>{children}</FilesDispatchProvider>
    ),
  });
  if (!result.current) throw new Error("uploader hook returned null");

  const pending = result.current.upload("file-1", [new File(["x"], "huge.srt", { type: "text/plain" })]);
  let settled = false;
  void pending.then(() => {
    settled = true;
  });
  await Promise.resolve();
  expect(settled).toBe(false);
  expect(scheduledUploads).toHaveLength(1);
  expect(dispatched.some((action) => action.type === "start-subtitle-upload")).toBe(true);

  scheduledUploads[0]?.onError?.();
  await pending;
  expect(settled).toBe(true);
  expect(alerts).toEqual([{ message: "Subtitle upload failed.", level: "error" }]);
  expect(dispatched).toContainEqual({
    type: "remove-subtitle",
    fileId: "file-1",
    subtitleUrl: expect.any(String) as string,
  });
});
