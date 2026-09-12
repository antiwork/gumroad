// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Pending, {
  PENDING_RELOAD_GIVE_UP_MS,
  PENDING_RELOAD_MS,
  PENDING_RELOAD_STARTED_AT_KEY,
} from "$app/pages/Checkout/Returns/Pending";

vi.mock("$app/components/ui/Card", () => ({
  Card: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  sessionStorage.clear();
});

describe("Checkout/Returns/Pending", () => {
  const reload = vi.fn();

  beforeEach(() => {
    reload.mockReset();
    vi.stubGlobal("location", {
      pathname: "/checkout/returns/order-token",
      reload,
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
    sessionStorage.setItem(
      `${PENDING_RELOAD_STARTED_AT_KEY}:/checkout/returns/order-token`,
      String(Date.now() - PENDING_RELOAD_GIVE_UP_MS),
    );

    render(<Pending />);
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
  });

  it("clears the reload timeout on unmount", () => {
    vi.useFakeTimers();
    const { unmount } = render(<Pending />);
    unmount();
    vi.advanceTimersByTime(PENDING_RELOAD_MS);

    expect(reload).not.toHaveBeenCalled();
  });
});
