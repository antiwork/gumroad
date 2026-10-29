// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Layout } from "$app/components/Settings/Layout";

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children, ...props }: React.ComponentProps<"a">) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
  usePage: () => ({ props: {} }),
}));

// happy-dom has no ResizeObserver, and the header pads its scrolling parent on resize.
class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = NoopResizeObserver as unknown as typeof ResizeObserver;

beforeEach(() => {
  Object.assign(globalThis, {
    Routes: {
      mcp_path: () => "/mcp",
      settings_main_path: () => "/settings",
      settings_password_path: () => "/settings/password",
      settings_authorized_applications_path: () => "/settings/authorized_applications",
    },
  });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("Settings layout navigation", () => {
  it("links to the connector page even when no applications are authorized", () => {
    render(
      <Layout pages={["main", "password"]} currentPage="main">
        <div>content</div>
      </Layout>,
    );

    expect(screen.getByRole("tab", { name: "AI connectors" }).getAttribute("href")).toBe("/mcp");
  });

  it("places the connector entry next to Applications when that page is shown", () => {
    render(
      <Layout pages={["main", "authorized_applications", "password"]} currentPage="main">
        <div>content</div>
      </Layout>,
    );

    const hrefs = screen.getAllByRole("tab").map((tab) => tab.getAttribute("href"));
    expect(hrefs).toEqual(["/settings", "/settings/authorized_applications", "/mcp", "/settings/password"]);
  });
});
