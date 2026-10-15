// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { DiscountExpirationCountdown } from "$app/components/Product/DiscountExpirationCountdown";

const abort = vi.fn();
const countdownConstructor = vi.fn();

vi.mock("$app/utils/countdown", () => ({
  default: class FakeCountdown {
    constructor(...args: unknown[]) {
      countdownConstructor(...args);
    }
    abort() {
      abort();
    }
  },
}));

afterEach(() => {
  cleanup();
  abort.mockClear();
  countdownConstructor.mockClear();
});

describe("DiscountExpirationCountdown", () => {
  it("aborts its Countdown interval when it unmounts", () => {
    // Regression for #6433: the Countdown was constructed inside useRunOnce and never aborted, so
    // navigating away from a product page left a 1-second setInterval ticking into an unmounted
    // component.
    const expiresAt = new Date(Date.now() + 60_000);
    const { unmount } = render(<DiscountExpirationCountdown expiresAt={expiresAt} onExpiration={() => undefined} />);

    expect(countdownConstructor).toHaveBeenCalledTimes(1);
    expect(abort).not.toHaveBeenCalled();

    unmount();

    expect(abort).toHaveBeenCalledTimes(1);
  });

  it("does not construct a Countdown when the discount has already expired", () => {
    const expiresAt = new Date(Date.now() - 1_000);
    const onExpiration = vi.fn();
    render(<DiscountExpirationCountdown expiresAt={expiresAt} onExpiration={onExpiration} />);

    expect(onExpiration).toHaveBeenCalledTimes(1);
    expect(countdownConstructor).not.toHaveBeenCalled();
  });

  it("shows a distant sale end date while keeping its expiration timer active", () => {
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    const { container } = render(
      <DiscountExpirationCountdown expiresAt={expiresAt} showEndDate onExpiration={() => undefined} />,
    );

    expect(container.textContent).toContain("This sale ends on");
    expect(container.querySelector("time")?.dateTime).toBe(expiresAt.toISOString());
    expect(countdownConstructor).toHaveBeenCalledTimes(1);
  });

  it("keeps distant expiry details hidden unless requested", () => {
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    const { container } = render(<DiscountExpirationCountdown expiresAt={expiresAt} onExpiration={() => undefined} />);

    expect(container.textContent).toBe("");
  });
});
