// @vitest-environment happy-dom
import Evaporate from "$vendor/evaporate.cjs";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

// A minimal XMLHttpRequest stand-in for the four requests Evaporate makes: the initiate POST
// (`?uploads`), the signer GET, the part PUTs, and the complete POST.
type Responder = (xhr: FakeXhr) => void;

class FakeXhr {
  static partResponders: Responder[] = [];
  static partRequests = 0;
  static hungRequests: FakeXhr[] = [];

  method = "";
  url = "";
  status = 0;
  response = "";
  responseText = "";
  readyState = 0;
  aborted = false;
  onreadystatechange: () => void = () => {};
  onerror: () => void = () => {};
  upload: { onprogress?: (event: { loaded: number }) => void } = {};

  open(method: string, url: string) {
    this.method = method;
    this.url = url;
  }

  setRequestHeader() {}

  getResponseHeader(name: string) {
    return name === "ETag" ? '"part-etag"' : null;
  }

  // Like a browser: aborting an unfinished request fires readystatechange with status 0.
  abort() {
    this.aborted = true;
    if (this.readyState !== 4) this.respond(0, "");
  }

  send() {
    if (this.url.includes("?uploads")) {
      this.respond(200, "<UploadId>upload-1</UploadId>");
    } else if (this.url === "http://s3.test/time") {
      // setupRequest reads the server time synchronously, so no handler fires here.
      this.status = 200;
      this.responseText = new Date().toUTCString();
    } else if (this.url.startsWith("http://s3.test/sign")) {
      this.respond(200, "s".repeat(28));
    } else if (this.url.includes("partNumber=")) {
      const responder =
        FakeXhr.partResponders[Math.min(FakeXhr.partRequests, FakeXhr.partResponders.length - 1)] ??
        ((partXhr: FakeXhr) => partXhr.respond(500, ""));
      FakeXhr.partRequests += 1;
      responder(this);
    } else {
      this.respond(200, "<CompleteMultipartUploadResult/>");
    }
  }

  respond(status: number, response: string) {
    this.status = status;
    this.response = response;
    this.readyState = 4;
    this.onreadystatechange();
  }
}

const hang: Responder = (xhr) => FakeXhr.hungRequests.push(xhr);

const buildEvaporate = (maxRetryAttempts: number, partSize?: number) =>
  // partSize is read at runtime but not part of the typed config.
  new Evaporate({
    ...(partSize ? { partSize } : {}),
    signerUrl: "http://s3.test/sign",
    aws_key: "key",
    bucket: "bucket",
    fetchCurrentServerTimeUrl: "http://s3.test/time",
    s3Endpoint: "http://s3.test",
    maxFileSize: 100 * 1024 * 1024,
    maxRetryAttempts,
  });

const addFile = (
  evaporate: InstanceType<typeof Evaporate>,
  callbacks: { complete: () => void; error: (message?: string) => void },
) =>
  evaporate.add({
    name: "huge.zip",
    file: new File([new Uint8Array(10)], "huge.zip"),
    url: "http://s3.test/bucket",
    mimeType: "application/zip",
    xAmzHeadersAtInitiate: { "x-amz-acl": "private" },
    complete: callbacks.complete,
    error: callbacks.error,
    progress() {},
    initiated() {},
  });

beforeEach(() => {
  FakeXhr.partResponders = [];
  FakeXhr.partRequests = 0;
  FakeXhr.hungRequests = [];
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
  await new Promise((resolve) => setTimeout(resolve, 1500));

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
