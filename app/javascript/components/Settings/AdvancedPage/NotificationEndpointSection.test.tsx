// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import NotificationEndpointSection, {
  PingDelivery,
} from "$app/components/Settings/AdvancedPage/NotificationEndpointSection";

const mocks = vi.hoisted(() => ({ request: vi.fn(), showAlert: vi.fn() }));
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request: mocks.request,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.showAlert }));

beforeEach(() => {
  mocks.request.mockReset();
  Object.assign(globalThis, {
    Routes: {
      ping_path: () => "/ping",
      test_pings_path: () => "/test_pings",
      settings_rotate_ping_signing_secret_path: () => "/settings/advanced/rotate_ping_signing_secret",
      settings_disable_ping_signing_path: () => "/settings/advanced/disable_ping_signing",
    },
  });
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

const delivery = (overrides: Partial<PingDelivery>): PingDelivery => ({
  id: 1,
  resource_name: "sale",
  sale_id: "805306969",
  subscription_id: null,
  post_url: "https://example.com/ping",
  attempt: 1,
  outcome: "HTTP 200",
  succeeded: true,
  created_at: "2026-09-29T12:00:00Z",
  ...overrides,
});

const renderSection = (deliveries: PingDelivery[], pingSigningSecret: string | null = null) =>
  render(
    <NotificationEndpointSection
      pingEndpoint=""
      setPingEndpoint={() => {}}
      pingSigningSecret={pingSigningSecret}
      userId="123"
      recentDeliveries={deliveries}
    />,
  );

describe("recent ping deliveries", () => {
  it("names a sale once, not twice", () => {
    renderSection([delivery({})]);
    expect(screen.getByText("Sale #805306969")).toBeTruthy();
    expect(screen.queryByText("Sale · Sale #805306969")).toBeNull();
  });

  it("keeps the event prefix when it adds information", () => {
    renderSection([delivery({ id: 2, resource_name: "refund" })]);
    expect(screen.getByText("Refund · Sale #805306969")).toBeTruthy();
  });

  it("labels an event without a sale by its name alone", () => {
    renderSection([delivery({ id: 3, resource_name: "subscription_ended", sale_id: null })]);
    expect(screen.getByText("Subscription ended")).toBeTruthy();
  });

  it("reports the attempt the row records, including a failed one", () => {
    renderSection([delivery({ id: 4, attempt: 3, outcome: "HTTP 503", succeeded: false })]);
    expect(screen.getByText("Not delivered — HTTP 503 (attempt 3)")).toBeTruthy();
  });
});

describe("ping signing", () => {
  it("offers signing when the seller has no secret", () => {
    renderSection([]);

    expect(screen.getByRole("button", { name: "Sign my pings" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Rotate" })).toBeNull();
  });

  it("turns signing on and shows the secret the server generated", async () => {
    mocks.request.mockResolvedValue(new Response(JSON.stringify({ success: true, secret: "abc123" }), { status: 200 }));
    renderSection([]);

    fireEvent.click(screen.getByRole("button", { name: "Sign my pings" }));

    await waitFor(() =>
      expect(mocks.request).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "/settings/advanced/rotate_ping_signing_secret",
          method: "POST",
        }),
      ),
    );
    expect(await screen.findByDisplayValue("abc123")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Rotate" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Turn off signing" })).toBeTruthy();
  });

  it("asks before rotating the secret", () => {
    renderSection([], "abc123");

    fireEvent.click(screen.getByRole("button", { name: "Rotate" }));

    expect(screen.getByText("Your endpoint will reject pings until it uses the new secret.")).toBeTruthy();
    expect(mocks.request).not.toHaveBeenCalled();
  });

  it("shows the existing secret and turns signing off", async () => {
    mocks.request.mockResolvedValue(new Response(JSON.stringify({ success: true }), { status: 200 }));
    renderSection([], "abc123");

    expect(screen.getByDisplayValue("abc123")).toBeTruthy();
    expect(screen.getByText(/Rotating replaces the secret right away/u)).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "Turn off signing" }));
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));

    await waitFor(() =>
      expect(mocks.request).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "/settings/advanced/disable_ping_signing",
          method: "DELETE",
        }),
      ),
    );
    await waitFor(() => expect(screen.queryByDisplayValue("abc123")).toBeNull());
    expect(screen.getByRole("button", { name: "Sign my pings" })).toBeTruthy();
  });

  it("keeps the secret when the server refuses the rotation", async () => {
    mocks.request.mockResolvedValue(
      new Response(JSON.stringify({ success: false, error_message: "Something went wrong." }), { status: 200 }),
    );
    renderSection([], "abc123");

    fireEvent.click(screen.getByRole("button", { name: "Rotate" }));
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));

    await waitFor(() => expect(mocks.showAlert).toHaveBeenCalledWith("Something went wrong.", "error"));
    expect(screen.getByDisplayValue("abc123")).toBeTruthy();
  });
});
