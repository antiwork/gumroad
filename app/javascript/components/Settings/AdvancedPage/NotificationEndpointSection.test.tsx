// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import NotificationEndpointSection, {
  PingDelivery,
} from "$app/components/Settings/AdvancedPage/NotificationEndpointSection";

beforeEach(() => {
  Object.assign(globalThis, {
    Routes: {
      ping_path: () => "/ping",
      test_pings_path: () => "/test_pings",
    },
  });
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
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

const renderSection = (deliveries: PingDelivery[]) =>
  render(
    <NotificationEndpointSection
      pingEndpoint=""
      setPingEndpoint={() => {}}
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
