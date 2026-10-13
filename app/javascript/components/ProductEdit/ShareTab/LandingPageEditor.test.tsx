// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { LandingPageEditor } from "$app/components/ProductEdit/ShareTab/LandingPageEditor";
import { showAlert } from "$app/components/server-components/Alert";

Object.assign(globalThis, {
  Routes: { link_path: (permalink: string) => `/links/${permalink}` },
});

const state = vi.hoisted(() => ({
  requests: new Array<{ url: string; method?: string; data?: unknown }>(),
  responses: new Array<{ ok: boolean; body: unknown }>(),
}));

vi.mock("$app/utils/request", () => ({
  request: (settings: { url: string; method?: string; data?: unknown }) => {
    state.requests.push(settings);
    const next = state.responses.shift() ?? { ok: true, body: { success: true } };
    return Promise.resolve({ ok: next.ok, json: () => Promise.resolve(next.body) });
  },
  ResponseError: class ResponseError extends Error {},
  assertResponseError: (e: unknown) => {
    if (!(e instanceof Error)) throw e;
  },
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

// The confirmation is a radix portal; render it inline so the whole flow stays in the tested tree.
vi.mock("$app/components/Modal", () => ({
  Modal: ({ children, footer }: { children: React.ReactNode; footer?: React.ReactNode }) => (
    <div>
      {children}
      {footer}
    </div>
  ),
}));

const onRemoved = vi.fn();

const renderEditor = (hasLandingPage: boolean) =>
  render(
    <LandingPageEditor
      uniquePermalink="bundle-permalink"
      url="https://seller.gumroad.com/l/bundle-permalink"
      hasLandingPage={hasLandingPage}
      onRemoved={onRemoved}
    />,
  );

const removeLandingPage = async () => {
  fireEvent.click(screen.getByRole("button", { name: "Remove landing page" }));
  fireEvent.click(screen.getByRole("button", { name: "Remove" }));
  await waitFor(() => expect(state.requests).toHaveLength(1));
};

describe("LandingPageEditor", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    state.requests = [];
    state.responses = [];
  });
  afterEach(cleanup);

  it("clears the live page on the product the caller points it at", async () => {
    renderEditor(true);
    expect(screen.getByText("A custom landing page is live on this product.")).toBeDefined();

    await removeLandingPage();

    expect(state.requests[0]).toMatchObject({
      method: "POST",
      url: "/links/bundle-permalink",
      data: { custom_html: null },
    });
    await waitFor(() => expect(onRemoved).toHaveBeenCalledTimes(1));
    expect(showAlert).toHaveBeenCalledWith("Landing page removed.", "success");
  });

  it("offers no removal when no page is live", () => {
    renderEditor(false);

    expect(screen.queryByText("A custom landing page is live on this product.")).toBeNull();
    expect(screen.queryByRole("button", { name: "Remove landing page" })).toBeNull();
  });

  it("keeps the page when the server refuses", async () => {
    state.responses.push({ ok: false, body: { success: false, message: "Not yours" } });
    renderEditor(true);

    await removeLandingPage();

    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Not yours", "error"));
    expect(onRemoved).not.toHaveBeenCalled();
  });
});
