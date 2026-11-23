// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { HomeFooter } from "$app/components/Home/Shared/Footer";

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  usePage: () => ({ props: {} }),
}));

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it("names the newsletter controls and the five social destinations", () => {
  vi.stubGlobal("Routes", {
    discover_path: () => "/discover",
    gumroad_blog_root_path: () => "/blog",
    pricing_path: () => "/pricing",
    features_path: () => "/features",
    about_path: () => "/about",
    gumclaw_path: () => "/gumclaw",
    small_bets_path: () => "/small-bets",
    help_center_root_path: () => "/help",
    terms_path: () => "/terms",
    privacy_path: () => "/privacy",
  });
  render(<HomeFooter />);
  expect(screen.getByRole("textbox", { name: "Email address" }).getAttribute("type")).toBe("email");
  expect(screen.getByRole("button", { name: "Subscribe" }).getAttribute("type")).toBe("submit");

  for (const destination of ["X", "YouTube", "Instagram", "Facebook", "Pinterest"]) {
    const link = screen.getByRole("link", { name: `Gumroad on ${destination}` });
    expect(link.querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
  }
});
