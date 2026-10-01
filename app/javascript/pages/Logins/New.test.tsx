// @vitest-environment happy-dom
import { act, cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import LoginPage from "$app/pages/Logins/New";

const SLOW_NOTICE = /taking longer than usual/i;

// The page renders inside an Inertia app with Rails routes exposed as a `Routes` global; neither
// exists under vitest, so stub the routes and drive `form.processing` from the test.
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

const form = vi.hoisted(() => ({ processing: false }));

vi.mock("@inertiajs/react", () => ({
  useForm: () => ({
    data: { user: { login_identifier: "seller@example.com", password: "hunter2" } },
    setData: () => undefined,
    post: () => undefined,
    processing: form.processing,
  }),
  usePage: () => ({
    props: {
      email: null,
      application_name: null,
      authenticity_token: "test-csrf",
      passkey_login_options: null,
      is_gumroad_mobile_app: false,
    },
  }),
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));

vi.mock("$app/components/Authentication/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("$app/components/Authentication/SocialAuth", () => ({ SocialAuth: () => null }));

const advance = (ms: number) =>
  act(() => {
    vi.advanceTimersByTime(ms);
  });

afterEach(cleanup);
beforeEach(() => {
  form.processing = false;
  vi.useFakeTimers();
});
afterEach(() => vi.useRealTimers());

describe("login form on a slow connection", () => {
  it("surfaces a slow-connection notice instead of spinning forever", () => {
    form.processing = true;
    render(<LoginPage />);
    expect((screen.getByRole("button", { name: "Logging in..." }) as HTMLButtonElement).disabled).toBe(true);

    advance(15_000);

    expect(screen.getByRole("alert").textContent).toMatch(SLOW_NOTICE);
  });

  it("keeps the form quiet when the visit resolves normally", () => {
    form.processing = true;
    const { rerender } = render(<LoginPage />);
    advance(1_000);

    form.processing = false;
    rerender(<LoginPage />);
    advance(60_000);

    expect(screen.queryByRole("alert")).toBeNull();
  });
});
