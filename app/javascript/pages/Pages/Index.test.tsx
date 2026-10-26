// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import PagesIndex from "$app/pages/Pages/Index";
import { cast } from "$app/utils/cast";

const mocks = vi.hoisted(() => ({ remove: vi.fn(), alert: vi.fn() }));
vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "/pages/about" }));
vi.mock("@inertiajs/react", () => ({
  Link: ({ children, ...props }: React.ComponentProps<"a">) => <a {...props}>{children}</a>,
  router: { delete: mocks.remove },
  usePage: () => ({
    props: {
      pages: [{ slug: "about", title: "About", content: "Hello", custom_html: false }],
      profile: { username: "seller", profile_url: "https://seller.example.com", custom_html: false },
      product_pages_count: 0,
    },
  }),
}));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { page: { create: true } } }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.alert }));

type Callbacks = { onSuccess: () => void; onError: () => void; onFinish?: () => void };
const openDelete = () => {
  render(<PagesIndex />);
  fireEvent.click(screen.getByRole("button", { name: "Delete About" }));
  fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Delete" }));
  return cast<Callbacks>(mocks.remove.mock.calls[0]?.[1]);
};

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

describe("page deletion recovery", () => {
  it("prevents another delete while a request is pending", () => {
    openDelete();
    const pending = screen.getByRole<HTMLButtonElement>("button", { name: "Deleting..." });
    expect(pending.disabled).toBe(true);
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel" }).disabled).toBe(true);
    fireEvent.click(pending);
    expect(mocks.remove).toHaveBeenCalledTimes(1);
  });

  it("unlocks retry when a request finishes without a success or validation callback", () => {
    const callbacks = openDelete();
    act(() => callbacks.onFinish?.());
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel" }).disabled).toBe(false);
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Delete" }));
    expect(mocks.remove).toHaveBeenCalledTimes(2);
  });

  it("allows cancellation after a failed request finishes", () => {
    const callbacks = openDelete();
    act(() => callbacks.onFinish?.());
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("retains the validation error and unlocks the confirmation", () => {
    const callbacks = openDelete();
    act(() => {
      callbacks.onError();
      callbacks.onFinish?.();
    });
    expect(mocks.alert).toHaveBeenCalledWith("Failed to delete the page. Please try again.", "error");
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel" }).disabled).toBe(false);
  });

  it("does not reopen the confirmation when a successful request finishes", () => {
    const callbacks = openDelete();
    act(() => {
      callbacks.onSuccess();
      callbacks.onFinish?.();
    });
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
