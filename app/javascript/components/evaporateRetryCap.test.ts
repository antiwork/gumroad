// @vitest-environment happy-dom
import Evaporate from "$vendor/evaporate.cjs";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

// A minimal XMLHttpRequest stand-in for the four requests Evaporate makes: the initiate POST
// (`?uploads`), the signer GET, the part PUTs, and the complete POST.
type Responder = (xhr: FakeXhr) => void;

class FakeXhr {
  static partResponders: Responder[] = [];
  static partRequests = 0;

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

  abort() {
    this.aborted = true;
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

const flush = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const buildEvaporate = (maxRetryAttempts: number) =>
  new Evaporate({
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
  vi.stubGlobal("XMLHttpRequest", FakeXhr);
});

afterEach(() => {
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

  await flush(1500);

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

  await flush(1500);

  expect(error).not.toHaveBeenCalled();
  expect(complete).toHaveBeenCalledTimes(1);
  expect(FakeXhr.partRequests).toBe(2);
});
