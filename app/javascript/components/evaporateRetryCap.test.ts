// @vitest-environment happy-dom
import Evaporate from "$vendor/evaporate.js";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

// A minimal XMLHttpRequest stand-in for the requests Evaporate makes: the server-time GET, the
// signer GET, the initiate POST (`?uploads`), the part PUTs, and the complete POST.
type Responder = (xhr: FakeXhr) => void;

const TIME_URL = "http://s3.test/time";
const SIGNER_URL = "http://s3.test/sign";

class FakeXhr {
  static partResponders: Responder[] = [];
  static partRequests = 0;
  static timeRequests = 0;
  static requests: FakeXhr[] = [];
  static hungRequests: FakeXhr[] = [];
  static hangComplete = false;
  static hangWhen: (xhr: FakeXhr) => boolean = () => false;
  static networkErrorWhen: (xhr: FakeXhr) => boolean = () => false;
  static completeResponse = "<CompleteMultipartUploadResult/>";

  method = "";
  url = "";
  async = true;
  body: unknown = null;
  timeLookup = 0;
  etag: string | null = '"part-etag"';
  status = 0;
  response = "";
  responseText = "";
  readyState = 0;
  aborted = false;
  onreadystatechange: () => void = () => {};
  onerror: () => void = () => {};
  upload: { onprogress?: (event: { loaded: number }) => void } = {};

  open(method: string, url: string, async = true) {
    this.method = method;
    this.url = url;
    this.async = async;
  }

  setRequestHeader() {}

  getResponseHeader(name: string) {
    return name === "ETag" ? this.etag : null;
  }

  // Like a browser: aborting an unfinished request fires readystatechange with status 0.
  abort() {
    this.aborted = true;
    if (this.readyState !== 4) this.respond(0, "");
  }

  send(body: unknown = null) {
    this.body = body;
    FakeXhr.requests.push(this);
    if (this.url === TIME_URL) this.timeLookup = ++FakeXhr.timeRequests;

    if (FakeXhr.hangWhen(this)) {
      // A fake cannot block the thread the way a browser's synchronous request does.
      if (!this.async) throw new Error("A synchronous request that never answers blocks the page");
      FakeXhr.hungRequests.push(this);
    } else if (FakeXhr.networkErrorWhen(this)) {
      // Browsers report a network failure as readystatechange (status 0) and then error.
      this.respond(0, "");
      this.onerror();
    } else if (this.url.includes("?uploads")) {
      this.respond(200, "<UploadId>upload-1</UploadId>");
    } else if (this.url === TIME_URL) {
      this.respond(200, new Date().toUTCString());
    } else if (this.url.startsWith(SIGNER_URL)) {
      this.respond(200, "s".repeat(28));
    } else if (this.url.includes("partNumber=")) {
      const responder =
        FakeXhr.partResponders[Math.min(FakeXhr.partRequests, FakeXhr.partResponders.length - 1)] ??
        ((partXhr: FakeXhr) => partXhr.respond(500, ""));
      FakeXhr.partRequests += 1;
      responder(this);
    } else if (FakeXhr.hangComplete) {
      FakeXhr.hungRequests.push(this);
    } else if (String(body).includes("<ETag>null</ETag>")) {
      this.respond(400, "<Error><Code>InvalidPart</Code></Error>");
    } else {
      this.respond(200, FakeXhr.completeResponse);
    }
  }

  respond(status: number, response: string) {
    this.status = status;
    this.response = response;
    this.responseText = response;
    this.readyState = 4;
    this.onreadystatechange();
  }
}

const hang: Responder = (xhr) => FakeXhr.hungRequests.push(xhr);

const isCompleteRequest = (xhr: FakeXhr) => xhr.method === "POST" && xhr.url.includes("?uploadId=");

// The signer URL carries the S3 request it signs, e.g. "POST\n...\n/bucket/huge.zip?uploads".
const isSignerFor =
  (step: "initiate" | "complete", fileName = "huge.zip") =>
  (xhr: FakeXhr) => {
    if (!xhr.url.startsWith(SIGNER_URL)) return false;
    const signed = new URL(xhr.url).searchParams.get("to_sign") ?? "";
    if (!signed.includes(`/bucket/${fileName}?`)) return false;
    return step === "initiate" ? signed.endsWith("?uploads") : signed.includes("?uploadId=");
  };

const buildEvaporate = (maxRetryAttempts: number, partSize?: number) =>
  // partSize is read at runtime but not part of the typed config.
  new Evaporate({
    ...(partSize ? { partSize } : {}),
    signerUrl: SIGNER_URL,
    aws_key: "key",
    bucket: "bucket",
    fetchCurrentServerTimeUrl: TIME_URL,
    s3Endpoint: "http://s3.test",
    maxFileSize: 100 * 1024 * 1024,
    maxRetryAttempts,
  });

const addFile = (
  evaporate: InstanceType<typeof Evaporate>,
  callbacks: { complete: () => void; error: (message?: string) => void; progress?: () => void },
  name = "huge.zip",
) =>
  evaporate.add({
    name,
    file: new File([new Uint8Array(10)], name),
    url: "http://s3.test/bucket",
    mimeType: "application/zip",
    xAmzHeadersAtInitiate: { "x-amz-acl": "private" },
    complete: callbacks.complete,
    error: callbacks.error,
    progress: callbacks.progress ?? (() => {}),
    initiated() {},
  });

beforeEach(() => {
  FakeXhr.partResponders = [];
  FakeXhr.partRequests = 0;
  FakeXhr.timeRequests = 0;
  FakeXhr.requests = [];
  FakeXhr.hungRequests = [];
  FakeXhr.hangComplete = false;
  FakeXhr.hangWhen = () => false;
  FakeXhr.networkErrorWhen = () => false;
  FakeXhr.completeResponse = "<CompleteMultipartUploadResult/>";
  vi.stubGlobal("XMLHttpRequest", FakeXhr);
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it("fails the file once a part exhausts its retry budget instead of retrying forever", async () => {
  // Every attempt on the part fails; the cap is 2, so the second failure is the last one.
  FakeXhr.partResponders = [
    (xhr) => xhr.respond(500, ""),
    (xhr) => xhr.respond(500, ""),
    (xhr) => xhr.respond(500, ""),
  ];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(error).toHaveBeenCalledTimes(1), { timeout: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  // Two attempts on the part, then the file failed rather than queueing a third.
  expect(FakeXhr.partRequests).toBe(2);
});

it("completes the file when a part recovers inside the retry budget", async () => {
  // The part fails once and succeeds on the retry, below the cap of 3.
  FakeXhr.partResponders = [(xhr) => xhr.respond(500, ""), (xhr) => xhr.respond(200, "")];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(3);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1), { timeout: 5000 });

  expect(error).not.toHaveBeenCalled();
  expect(complete).toHaveBeenCalledTimes(1);
  expect(FakeXhr.partRequests).toBe(2);
});

it("aborts the other in-flight parts when one part exhausts its budget", async () => {
  // Two 5-byte parts: part 1 always fails, part 2 never answers.
  FakeXhr.partResponders = [(xhr) => (xhr.url.includes("partNumber=1") ? xhr.respond(500, "") : hang(xhr))];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2, 5);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(error).toHaveBeenCalledTimes(1), { timeout: 5000 });
  const requestsAtFailure = FakeXhr.partRequests;
  // failUpload cancels every in-flight request, so wait for the abort rather than a fixed delay.
  await vi.waitFor(() => expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true), { timeout: 5000 });

  expect(FakeXhr.hungRequests.length).toBeGreaterThan(0);
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.partRequests).toBe(requestsAtFailure);
  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
});

it("fails the file once a permanently stalled part is aborted past its budget", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [hang];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  // Each attempt costs two 2-minute stall-monitor ticks before it is aborted.
  await vi.advanceTimersByTimeAsync(9 * 60 * 1000);

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.partRequests).toBe(2);
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
});

it("fails the file when the completion request never answers", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangComplete = true;
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(6 * 60 * 1000);

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
});

it("uploads every part and completes once with each part's ETag", async () => {
  // Two 5-byte parts, each answering with its own ETag.
  FakeXhr.partResponders = [
    (xhr) => {
      xhr.etag = `"etag-${new URL(xhr.url).searchParams.get("partNumber")}"`;
      xhr.respond(200, "");
    },
  ];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2, 5);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1), { timeout: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(complete).toHaveBeenCalledTimes(1);
  expect(error).not.toHaveBeenCalled();
  expect(FakeXhr.requests.filter(isCompleteRequest).map((xhr) => xhr.body)).toEqual([
    '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"etag-1"</ETag></Part>' +
      '<Part><PartNumber>2</PartNumber><ETag>"etag-2"</ETag></Part></CompleteMultipartUpload>',
  ]);
});

it("fails the file when the initiate request never answers", async () => {
  vi.useFakeTimers();
  FakeXhr.hangWhen = (xhr) => xhr.method === "POST" && xhr.url.endsWith("?uploads");
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(2 * 60 * 1000 + 1000);

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
});

it("looks up the server time without blocking and falls back to the local clock when it never answers", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangWhen = (xhr) => xhr.timeLookup === 1;
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(29 * 1000);
  expect(FakeXhr.requests.some((xhr) => xhr.url.startsWith(SIGNER_URL))).toBe(false);

  await vi.advanceTimersByTimeAsync(2 * 1000);

  expect(complete).toHaveBeenCalledTimes(1);
  expect(error).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.requests.filter((xhr) => xhr.url === TIME_URL).every((xhr) => xhr.async)).toBe(true);
});

it("still completes the file when the completion's server time lookup never answers", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  // Lookups run for the initiate, the single part, then the completion.
  FakeXhr.hangWhen = (xhr) => xhr.timeLookup === 3;
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(31 * 1000);

  expect(complete).toHaveBeenCalledTimes(1);
  expect(error).not.toHaveBeenCalled();
  expect(FakeXhr.requests.filter(isCompleteRequest)).toHaveLength(1);
});

it("fails the file when the signer never answers for the initiate request", async () => {
  vi.useFakeTimers();
  FakeXhr.hangWhen = isSignerFor("initiate");
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(61 * 1000);

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.length).toBe(1);
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.requests.some((xhr) => xhr.method === "POST")).toBe(false);

  await vi.advanceTimersByTimeAsync(10 * 60 * 1000);
  expect(error).toHaveBeenCalledTimes(1);
});

it("fails the file when the signer never answers for the completion request", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangWhen = isSignerFor("complete");
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(61 * 1000);

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.length).toBe(1);
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.requests.filter(isCompleteRequest)).toHaveLength(0);
});

it("fails the file when S3 answers the completion with 200 and an error body", async () => {
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.completeResponse =
    "<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>";
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(error).toHaveBeenCalledTimes(1), { timeout: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
});

it("retries a part whose response hides its ETag instead of completing with a null ETag", async () => {
  FakeXhr.partResponders = [
    (xhr) => {
      xhr.etag = null;
      xhr.respond(200, "");
    },
    (xhr) => xhr.respond(200, ""),
  ];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(3);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1), { timeout: 5000 });

  expect(error).not.toHaveBeenCalled();
  expect(FakeXhr.partRequests).toBe(2);
  expect(FakeXhr.requests.filter(isCompleteRequest).map((xhr) => xhr.body)).toEqual([
    '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"part-etag"</ETag></Part></CompleteMultipartUpload>',
  ]);
});

it("fails the file without sending a completion when no part response exposes an ETag", async () => {
  FakeXhr.partResponders = [
    (xhr) => {
      xhr.etag = null;
      xhr.respond(200, "");
    },
  ];
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(error).toHaveBeenCalledTimes(1), { timeout: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.partRequests).toBe(2);
  expect(FakeXhr.requests.filter(isCompleteRequest)).toHaveLength(0);
});

it("reports nothing after the seller cancels while the completion is being signed", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangWhen = isSignerFor("complete");
  const complete = vi.fn();
  const error = vi.fn();
  const progress = vi.fn();

  const evaporate = buildEvaporate(2);
  const id = addFile(evaporate, { complete, error, progress });

  await vi.advanceTimersByTimeAsync(1000);
  expect(FakeXhr.hungRequests.length).toBe(1);
  evaporate.cancel(String(id));
  const progressCallsAtCancel = progress.mock.calls.length;

  await vi.advanceTimersByTimeAsync(10 * 60 * 1000);

  expect(error).not.toHaveBeenCalled();
  expect(complete).not.toHaveBeenCalled();
  expect(progress).toHaveBeenCalledTimes(progressCallsAtCancel);
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.requests.filter(isCompleteRequest)).toHaveLength(0);
});

it("does not sign or send the completion after the seller cancels during its server time lookup", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangWhen = (xhr) => xhr.timeLookup === 3;
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  const id = addFile(evaporate, { complete, error });

  await vi.advanceTimersByTimeAsync(1000);
  expect(FakeXhr.hungRequests.length).toBe(1);
  evaporate.cancel(String(id));

  await vi.advanceTimersByTimeAsync(10 * 60 * 1000);

  expect(error).not.toHaveBeenCalled();
  expect(complete).not.toHaveBeenCalled();
  expect(FakeXhr.hungRequests.every((xhr) => xhr.aborted)).toBe(true);
  expect(FakeXhr.requests.some(isSignerFor("complete"))).toBe(false);
  expect(FakeXhr.requests.filter(isCompleteRequest)).toHaveLength(0);
});

it("starts the next queued file once the previous one fails at completion", async () => {
  vi.useFakeTimers();
  FakeXhr.partResponders = [(xhr) => xhr.respond(200, "")];
  FakeXhr.hangWhen = isSignerFor("complete", "first.zip");
  const first = { complete: vi.fn(), error: vi.fn() };
  const second = { complete: vi.fn(), error: vi.fn() };

  const evaporate = buildEvaporate(2);
  addFile(evaporate, first, "first.zip");
  addFile(evaporate, second, "second.zip");

  await vi.advanceTimersByTimeAsync(61 * 1000);

  expect(first.error).toHaveBeenCalledTimes(1);
  expect(first.complete).not.toHaveBeenCalled();
  expect(second.complete).toHaveBeenCalledTimes(1);
  expect(second.error).not.toHaveBeenCalled();
});

it("reports a signer network failure once", async () => {
  FakeXhr.networkErrorWhen = isSignerFor("initiate");
  const complete = vi.fn();
  const error = vi.fn();

  const evaporate = buildEvaporate(2);
  addFile(evaporate, { complete, error });

  await vi.waitFor(() => expect(error).toHaveBeenCalled(), { timeout: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(error).toHaveBeenCalledTimes(1);
  expect(complete).not.toHaveBeenCalled();
});
