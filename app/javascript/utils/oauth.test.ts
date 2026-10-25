import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { startOauthRedirectChecker } from "$app/utils/oauth";

// The checker polls every 500 ms. Three ticks cover the tick that finds the code
// plus two more that used to see the popup the success path had already closed.
const POLL_INTERVAL_MS = 500;
const PAST_MULTIPLE_POLLS_MS = POLL_INTERVAL_MS * 3;

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

const setup = () => {
  const popup = {
    closed: false,
    location: { href: "https://example.com/oauth_redirect?code=authorization-code" },
    close: vi.fn(() => {
      popup.closed = true;
    }),
  };
  const onError = vi.fn();
  const onPopupClose = vi.fn();
  return { popup, onError, onPopupClose };
};

it("does not report cancellation while the authorization exchange is pending", async () => {
  const { popup, onError, onPopupClose } = setup();
  let finish!: () => void;
  const onSuccess = vi.fn(
    () =>
      new Promise<void>((resolve) => {
        finish = resolve;
      }),
  );
  startOauthRedirectChecker({
    // Only the location and close surface is used by the checker.
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
    oauthPopup: popup as unknown as Window,
    onSuccess,
    onError,
    onPopupClose,
  });

  await vi.advanceTimersByTimeAsync(PAST_MULTIPLE_POLLS_MS);

  expect(onSuccess).toHaveBeenCalledExactlyOnceWith("authorization-code");
  expect(popup.close).toHaveBeenCalledOnce();
  expect(onPopupClose).not.toHaveBeenCalled();
  expect(onError).not.toHaveBeenCalled();
  expect(vi.getTimerCount()).toBe(0);
  finish();
  await Promise.resolve();
});

it("reports an authorization exchange failure once", async () => {
  const { popup, onError, onPopupClose } = setup();
  startOauthRedirectChecker({
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
    oauthPopup: popup as unknown as Window,
    onSuccess: vi.fn().mockRejectedValue(new Error("Connection interrupted")),
    onError,
    onPopupClose,
  });
  await vi.advanceTimersByTimeAsync(PAST_MULTIPLE_POLLS_MS);
  expect(onError).toHaveBeenCalledOnce();
  expect(onPopupClose).not.toHaveBeenCalled();
});

it("reports a blocked or manually closed popup as cancellation", async () => {
  const onPopupClose = vi.fn();
  startOauthRedirectChecker({ oauthPopup: null, onSuccess: vi.fn(), onError: vi.fn(), onPopupClose });
  await vi.advanceTimersByTimeAsync(PAST_MULTIPLE_POLLS_MS);
  expect(onPopupClose).toHaveBeenCalledOnce();
  expect(vi.getTimerCount()).toBe(0);
});
