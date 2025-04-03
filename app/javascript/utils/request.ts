export type RequestSettings = {
  accept: "json" | "html" | "csv";
  url: string;
  abortSignal?: AbortSignal | undefined;
} & ({ method: "GET" } | { method: "POST" | "PUT" | "PATCH" | "DELETE"; data?: Record<string, unknown> | FormData });

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

export function assertResponseError(e: unknown): asserts e is ResponseError {
  if (!(e instanceof ResponseError)) throw e;
}

declare global {
  // eslint-disable-next-line -- hack, used in `wait_for_ajax` in testing
  var __activeRequests: number;
}
globalThis.__activeRequests = 0;

export const defaults: RequestInit = {};

export const request = async (settings: RequestSettings): Promise<Response> => {
  ++globalThis.__activeRequests;
  const data =
    settings.method === "GET"
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
  try {
    const response = await fetch(settings.url, {
      ...defaults,
      method: settings.method,
      body: data,
      headers,
      signal: settings.abortSignal ?? null,
    });
    if (response.status >= 500) throw new ResponseError();
    // We rate limit some endpoints to prevent brute force attacks. See config/initializers/rack_attack.rb
    if (response.status === 429) throw new ResponseError("Something went wrong, please try again after some time.");
    return response;
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") throw new AbortError();
    throw new ResponseError();
  } finally {
    --globalThis.__activeRequests;
  }
};
