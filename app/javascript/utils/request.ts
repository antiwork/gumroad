type RequestSettingsBase = {
  accept: "json" | "html" | "csv";
  url: string;
  abortSignal?: AbortSignal | undefined;
  headers?: Record<string, string> | undefined;
};

// `data?: never` on the bodyless member keeps `settings.data` readable without narrowing (TypeScript
// can't subtract single literals from the union-typed `method` discriminant) while still rejecting a
// GET/HEAD call that tries to pass a body.
export type RequestSettings =
  | (RequestSettingsBase & { method: "GET" | "HEAD"; data?: never })
  | (RequestSettingsBase & { method: "POST" | "PUT" | "PATCH" | "DELETE"; data?: Record<string, unknown> | FormData });

export class AbortError extends Error {
  constructor() {
    super("Request aborted");
  }
}

export class TimeoutError extends Error {
  constructor() {
    super("Request timed out");
  }
}

export class ResponseError extends Error {
  constructor(message = "Something went wrong.") {
    super(message);
  }
}

// A 429 from an endpoint that rate limits per user. Distinct from a plain ResponseError so callers
// can tell "you have to wait" apart from "something broke" and say so — the two need very different
// wording, and showing a generic failure for a limit the user simply has to wait out sends people
// looking for a fault in their account that isn't there.
//
// `message` is the server's own explanation when it sent one, since only the server knows what the
// limit is and what counts towards it. `retryAfter` is the number of seconds until the window
// resets, when the server reported it.
export class RateLimitError extends ResponseError {
  retryAfter: number | null;

  constructor(message: string, retryAfter: number | null = null) {
    super(message);
    this.retryAfter = retryAfter;
  }
}

export function assertResponseError(e: unknown): asserts e is ResponseError {
  if (!(e instanceof ResponseError)) throw e;
}

declare global {
  // eslint-disable-next-line -- hack, used in `wait_for_ajax` in testing
  var __activeRequests: number;
}
globalThis.__activeRequests = 0;

export const defaults: RequestInit = {};

// Build a RateLimitError from a 429 response, preferring the server's own wording and countdown.
// The body is read defensively: not every rate-limited endpoint answers with JSON (Rack::Attack's
// blocklist responses, an HTML error page from a proxy), and a body we can't parse must still
// produce a usable message rather than an exception inside the error path.
const rateLimitError = async (response: Response): Promise<RateLimitError> => {
  const headerRetryAfter = Number(response.headers.get("Retry-After"));
  let retryAfter = Number.isFinite(headerRetryAfter) && headerRetryAfter > 0 ? headerRetryAfter : null;
  let message = "";
  try {
    const body: unknown = await response.json();
    if (body !== null && typeof body === "object") {
      if ("error" in body && typeof body.error === "string") message = body.error;
      // Prefer the body's number when the header didn't survive (a proxy stripping it, a fetch
      // whose exposed headers are restricted).
      if (
        retryAfter === null &&
        "retry_after" in body &&
        typeof body.retry_after === "number" &&
        body.retry_after > 0
      ) {
        retryAfter = body.retry_after;
      }
    }
  } catch {
    // Non-JSON or empty body — fall through to the generic wording below.
  }
  return new RateLimitError(
    message || "You're making requests too quickly. Please wait a moment and try again.",
    retryAfter,
  );
};

export const request = async (settings: RequestSettings): Promise<Response> => {
  ++globalThis.__activeRequests;
  const data =
    settings.method === "GET" || settings.method === "HEAD"
      ? null
      : settings.data instanceof FormData
        ? settings.data
        : JSON.stringify(settings.data);

  const acceptType = {
    json: "application/json, text/html",
    html: "text/html",
    csv: "text/csv",
  }[settings.accept];

  const headers = new Headers(defaults.headers);
  headers.set("Accept", acceptType);
  if (data && !(data instanceof FormData)) headers.set("Content-Type", "application/json");
  for (const [name, value] of Object.entries(settings.headers ?? {})) headers.set(name, value);
  try {
    const response = await fetch(settings.url, {
      ...defaults,
      method: settings.method,
      body: data,
      headers,
      signal: settings.abortSignal ?? null,
    });
    if (response.status >= 500) throw new ResponseError();
    // We rate limit some endpoints — to prevent brute force attacks (see
    // config/initializers/rack_attack.rb) and to cap expensive per-user work like the store agent's
    // LLM calls. Surface the server's own explanation and its Retry-After when it sent them: the
    // server is the only side that knows which limit was hit, what counts towards it, and how long
    // is left, and replacing that with a fixed generic string is what made a "wait an hour" into an
    // apparent malfunction for sellers.
    if (response.status === 429) throw await rateLimitError(response);
    return response;
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") throw new AbortError();
    // Errors we raised above already carry the right message; only genuine fetch/network failures
    // become a generic ResponseError.
    if (e instanceof ResponseError) throw e;
    throw new ResponseError();
  } finally {
    --globalThis.__activeRequests;
  }
};
