// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { BundleEditLayout } from "$app/components/BundleEdit/Layout";
import { CurrentSellerProvider } from "$app/components/CurrentSeller";

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  usePage: () => ({ component: "Bundles/Product/Edit" }),
}));
vi.mock("$app/components/DomainSettings", () => ({
  useDomains: () => ({ appDomain: "gumroad.com", scheme: "https" }),
}));
vi.mock("$app/components/Preview", () => ({ Preview: () => null }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));

const offsetHeightDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "offsetHeight");

beforeAll(() => {
  const url = (path: string) => () => path;
  Object.assign(globalThis, {
    Routes: {
      edit_bundle_content_path: url("/bundles/bundle/content"),
      edit_bundle_product_path: url("/bundles/bundle"),
      edit_bundle_share_path: url("/bundles/bundle/share"),
      short_link_url: url("/l/bundle"),
    },
  });
});

afterEach(() => {
  cleanup();
  if (offsetHeightDescriptor) Object.defineProperty(HTMLElement.prototype, "offsetHeight", offsetHeightDescriptor);
});

describe("BundleEditLayout", () => {
  it("publishes the sticky header height for the description editor toolbar", () => {
    Object.defineProperty(HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 120 });

    const { getByTestId } = render(
      <CurrentSellerProvider value={null}>
        <div data-testid="scroller">
          <BundleEditLayout id="bundle" isPublished={false}>
            <div role="toolbar" />
          </BundleEditLayout>
        </div>
      </CurrentSellerProvider>,
    );

    expect(getByTestId("scroller").style.getPropertyValue("--page-header-height")).toBe("120px");
  });

  it("shows the schedule from the latest server props", () => {
    const pending = { status: "scheduled", label: "December 2, 2026 at 9:30 AM PST", failure_message: null };
    const renderBundle = (publishSchedule: typeof pending | null) => (
      <CurrentSellerProvider value={null}>
        <BundleEditLayout id="bundle" uniquePermalink="bundle" isPublished={false} publishSchedule={publishSchedule}>
          <div />
        </BundleEditLayout>
      </CurrentSellerProvider>
    );

    const { rerender } = render(renderBundle(pending));
    expect(screen.getByText("Scheduled to publish on December 2, 2026 at 9:30 AM PST.")).toBeTruthy();

    rerender(renderBundle(null));
    expect(screen.queryByText(/Scheduled to publish/u)).toBeNull();
  });
});
