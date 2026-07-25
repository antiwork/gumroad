// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CloseOnNavigate } from "$app/components/CloseOnNavigate";

const close = vi.fn();

// CloseOnNavigate reads the nav drawer's close callback out of the Nav context. Rendering the whole
// Nav just to get that callback would drag in the page chrome, so stub the hook instead.
vi.mock("$app/components/Nav", () => ({ useNav: () => ({ open: true, close }) }));

// Inertia's router.on("before", …) is a document listener for the "inertia:before" event, so a
// visit can be simulated by dispatching that event with the visit object Inertia would attach.
const fireBefore = (visit: { prefetch: boolean }) =>
  document.dispatchEvent(new CustomEvent("inertia:before", { detail: { visit }, cancelable: true }));

afterEach(() => {
  cleanup();
  close.mockClear();
});

describe("CloseOnNavigate", () => {
  it("closes the nav drawer when a real navigation starts", () => {
    render(<CloseOnNavigate />);

    fireBefore({ prefetch: false });

    expect(close).toHaveBeenCalledTimes(1);
  });

  it("leaves the nav drawer open when the visit is only a prefetch", () => {
    // Sidebar links prefetch on hover, and on a phone a tap synthesises a mouseenter first. If the
    // prefetch closed the drawer, the link would vanish from under the user's finger and the first
    // tap would never register as a click.
    render(<CloseOnNavigate />);

    fireBefore({ prefetch: true });

    expect(close).not.toHaveBeenCalled();
  });
});
