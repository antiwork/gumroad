// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Pending, {
  PENDING_RELOAD_GIVE_UP_MS,
  PENDING_RELOAD_MS,
  PENDING_RELOAD_STARTED_AT_KEY,
  PENDING_STARTED_AT_PARAM,
} from "$app/pages/Checkout/Returns/Pending";

vi.mock("$app/components/ui/Card", () => ({
  Card: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

const PATH = "/checkout/returns/order-token";
const HREF = `https://gumroad.test${PATH}?payment_intent=pi_123`;

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  sessionStorage.clear();
});

describe("Checkout/Returns/Pending", () => {
  const reload = vi.fn();
  const replace = vi.fn();

  beforeEach(() => {
    reload.mockReset();
    replace.mockReset();
    vi.stubGlobal("location", {
      pathname: PATH,
      search: "?payment_intent=pi_123",
      href: HREF,
      reload,
      replace,
    });
  });

  it("reloads so a later successful finalize can redirect off this page", () => {
    vi.useFakeTimers();
    render(<Pending />);

    expect(screen.getByRole("heading", { name: "Your payment is being processed" })).toBeTruthy();
    expect(reload).not.toHaveBeenCalled();

    vi.advanceTimersByTime(PENDING_RELOAD_MS);
    expect(reload).toHaveBeenCalledTimes(1);
  });

  it("does not reload after the give-up window for this return URL", () => {
    vi.useFakeTimers();
    sessionStorage.setItem(`${PENDING_RELOAD_STARTED_AT_KEY}:${PATH}`, String(Date.now() - PENDING_RELOAD_GIVE_UP_MS));

    render(<Pending />);
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it("clears the reload timeout on unmount", () => {
    vi.useFakeTimers();
    const { unmount } = render(<Pending />);
    unmount();
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
  });

  it("still reloads when sessionStorage throws", () => {
    vi.useFakeTimers();
    vi.spyOn(sessionStorage, "getItem").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });

    render(<Pending />);
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
    expect(replace).toHaveBeenCalledTimes(1);
    const nextUrl = new URL(String(replace.mock.calls[0]?.[0]));
    expect(nextUrl.searchParams.get("payment_intent")).toBe("pi_123");
    expect(nextUrl.searchParams.get(PENDING_STARTED_AT_PARAM)).toMatch(/^\d+$/);
  });

  it("stops polling from the URL clock when sessionStorage is unavailable", () => {
    vi.useFakeTimers();
    const started = Date.now() - PENDING_RELOAD_GIVE_UP_MS;
    vi.stubGlobal("location", {
      pathname: PATH,
      search: `?payment_intent=pi_123&${PENDING_STARTED_AT_PARAM}=${started}`,
      href: `${HREF}&${PENDING_STARTED_AT_PARAM}=${started}`,
      reload,
      replace,
    });
    vi.spyOn(sessionStorage, "getItem").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });

    render(<Pending />);
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });
});
