// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { UtmLinkForm, type UtmLinkFormProps } from "$app/components/UtmLinks/UtmLinkForm";

// The form renders inside an Inertia app with Rails routes exposed as a `Routes` global.
// Neither exists under vitest, so stub the routes with placeholder hrefs — these tests
// assert which validation errors are displayed, not navigation.
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// Keep the real useForm (its error state is what's under test) but stub the router, which
// otherwise tries to read/write Inertia history state that does not exist here.
vi.mock("@inertiajs/react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inertiajs/react")>();
  return {
    ...actual,
    router: { ...actual.router, restore: () => undefined, remember: () => undefined, reload: () => undefined },
  };
});

// These subtrees need the logged-in-user context, tooltips, or clipboard APIs that are
// irrelevant to validation error state.
vi.mock("$app/components/Analytics/AnalyticsLayout", () => ({
  AnalyticsLayout: ({ children, actions }: { children: React.ReactNode; actions?: React.ReactNode }) => (
    <div>
      {actions}
      {children}
    </div>
  ),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/CopyToClipboard", () => ({
  CopyToClipboard: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/WithTooltip", () => ({
  WithTooltip: ({ children }: { children: React.ReactNode }) => children,
}));

const props: UtmLinkFormProps = {
  context: {
    destination_options: [{ id: "product-abc", label: "Product — Product A", url: "https://example.com/l/abc" }],
    short_url: "https://gum.new/u/shortlink",
    utm_fields_values: { campaigns: [], mediums: [], sources: [], terms: [], contents: [] },
  },
  utm_link: null,
};

const isFlagged = (label: string) =>
  screen.getByLabelText(label).closest("fieldset")?.classList.contains("danger") ?? false;

describe("UtmLinkForm validation errors", () => {
  afterEach(cleanup);

  it("clears only the edited field's error, leaving other fields' errors in place", () => {
    render(<UtmLinkForm {...props} />);

    // Nothing filled in: the first missing field (Title) is flagged.
    fireEvent.click(screen.getByRole("button", { name: "Add link" }));
    expect(isFlagged("Title")).toBe(true);

    // Filling Title clears its own error.
    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Test Link" } });
    expect(isFlagged("Title")).toBe(false);

    // Next submit flags Destination instead.
    fireEvent.click(screen.getByRole("button", { name: "Add link" }));
    expect(isFlagged("Destination")).toBe(true);

    // Editing an unrelated field must NOT wipe the Destination error. The form used to clear
    // every error from an effect keyed on the whole form data, which both dropped errors the
    // user had not addressed and could race a freshly-set error from the next submit — the
    // flake in spec/requests/analytics/utm_links_spec.rb "shows validation errors" (#6487).
    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Test Link renamed" } });
    expect(isFlagged("Destination")).toBe(true);
  });
});
