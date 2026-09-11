// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SocialAuthButton } from "$app/components/SocialAuthButton";

vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: { authenticity_token: "test-csrf" } }),
}));

afterEach(cleanup);

describe("SocialAuthButton", () => {
  it("uses the provider brand color when no override is passed", () => {
    render(
      <SocialAuthButton href="/auth/twitter" provider="twitter">
        Connect
      </SocialAuthButton>,
    );

    expect(screen.getByRole("button", { name: "Connect" }).className).toContain("bg-black");
  });

  it("uses the color override so Connect stays visible in dark mode", () => {
    // X/Twitter brand fill is black. On Settings → Social connections that is
    // black-on-black in dark mode; the page passes primary instead.
    render(
      <SocialAuthButton href="/auth/twitter" provider="twitter" color="primary">
        Connect
      </SocialAuthButton>,
    );

    const className = screen.getByRole("button", { name: "Connect" }).className;
    expect(className).toContain("bg-primary");
    expect(className).not.toContain("bg-black");
  });
});
