// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { isPasskeySupported } from "$app/utils/webauthn";

import { PasskeySetupPrompt } from "$app/components/PasskeySetupPrompt";

vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props: { prompt_passkey_setup: true } }) }));
vi.mock("$app/components/CurrentSeller", () => ({ useCurrentSeller: () => ({ id: "seller-1" }) }));
vi.mock("$app/utils/webauthn", () => ({ isPasskeySupported: vi.fn(() => true) }));

const key = "passkeySetupPromptSnoozedUntil:seller-1";

beforeEach(() => {
  localStorage.clear();
  vi.mocked(isPasskeySupported).mockReturnValue(true);
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("PasskeySetupPrompt", () => {
  it("persists a 90-day snooze when storage works", () => {
    const now = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(now);
    render(<PasskeySetupPrompt />);
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));

    expect(screen.queryByRole("button", { name: "Not now" })).toBeNull();
    expect(Number(localStorage.getItem(key))).toBe(now + 90 * 24 * 60 * 60 * 1000);
  });

  it("keeps an existing future snooze hidden", () => {
    localStorage.setItem(key, String(Date.now() + 60_000));
    render(<PasskeySetupPrompt />);
    expect(screen.queryByRole("button", { name: "Not now" })).toBeNull();
  });

  it("renders and dismisses when the storage getter is denied", () => {
    vi.spyOn(window, "localStorage", "get").mockImplementation(() => {
      throw new DOMException("Storage unavailable", "SecurityError");
    });
    render(<PasskeySetupPrompt />);
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));
    expect(screen.queryByRole("button", { name: "Not now" })).toBeNull();
  });

  it.each(["QuotaExceededError", "SecurityError"])("dismisses when a snooze write raises %s", (name) => {
    vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("Storage write unavailable", name);
    });
    render(<PasskeySetupPrompt />);
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));
    expect(screen.queryByRole("button", { name: "Not now" })).toBeNull();
  });

  it("does not access storage when passkeys are unsupported", () => {
    vi.mocked(isPasskeySupported).mockReturnValue(false);
    const getStorage = vi.spyOn(window, "localStorage", "get").mockImplementation(() => {
      throw new DOMException("Storage unavailable", "SecurityError");
    });
    render(<PasskeySetupPrompt />);
    expect(getStorage).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Not now" })).toBeNull();
  });
});
