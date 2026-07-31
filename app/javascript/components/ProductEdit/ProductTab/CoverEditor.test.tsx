// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AssetPreview } from "$app/parsers/product";

import { CoverEditor } from "$app/components/ProductEdit/ProductTab/CoverEditor";

// The real ReactSortable installs SortableJS on the DOM node, which needs layout happy-dom
// does not provide. Stub it to a plain wrapper that records the options it was handed: the
// bug here is entirely about which options reach SortableJS, so those options ARE the
// contract worth pinning.
type StubbedSortableProps = {
  children?: React.ReactNode;
  tag?: React.ElementType;
  list?: unknown;
  setList?: unknown;
  filter?: string;
  preventOnFilter?: boolean;
};
const sortableProps = vi.hoisted(() => {
  const box: { current: StubbedSortableProps | null } = { current: null };
  return box;
});
vi.mock("react-sortablejs", () => ({
  ReactSortable: ({ children, tag, list: _list, setList: _setList, ...options }: StubbedSortableProps) => {
    sortableProps.current = options;
    const Wrapper = tag ?? "div";
    return <Wrapper>{children}</Wrapper>;
  },
}));

// The remove button is hover-gated on desktop and always shown below `lg`. Report a small
// viewport so it renders unconditionally, which is the touch case this fix is about.
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));

// Radix's popover pulls in its own React copy under vitest's resolution and dies on
// `useMemo`. It is the "add cover" menu, unrelated to the drag surface under test, so stub
// it to plain wrappers rather than fighting the module graph.
vi.mock("$app/components/Popover", () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>;
  return {
    Popover: Passthrough,
    PopoverAnchor: Passthrough,
    PopoverContent: Passthrough,
    PopoverTrigger: Passthrough,
  };
});

afterEach(() => {
  cleanup();
  sortableProps.current = null;
});

const cover = (overrides: Partial<AssetPreview> = {}): AssetPreview => ({
  type: "image",
  filetype: "png",
  id: "cover-1",
  url: "https://example.test/cover.png",
  original_url: "https://example.test/cover-original.png",
  thumbnail: null,
  width: 1280,
  height: 720,
  native_width: 1280,
  native_height: 720,
  ...overrides,
});

const renderEditor = (covers: AssetPreview[]) =>
  render(<CoverEditor covers={covers} setCovers={() => {}} permalink="abc" />);

describe("CoverEditor cover removal on touch devices", () => {
  // Four separate support tickets and four manual prod-console soft-deletes came from this:
  // the whole cover tab is a drag surface, so SortableJS claimed the `touchstart` on the
  // remove button and the tap never became a click.
  // See https://github.com/antiwork/gumroad-private/issues/1524
  it("excludes the remove button from the drag surface", () => {
    renderEditor([cover()]);

    expect(sortableProps.current?.filter).toBe("[data-remove-cover]");
  });

  // The half that actually makes the tap work. SortableJS's `preventOnFilter` defaults to
  // true and calls `preventDefault()` on the filtered `touchstart` (sortable.esm.js: the
  // `preventOnFilter && evt.cancelable && evt.preventDefault()` on the filter path), which
  // cancels the synthetic click the browser would otherwise emit. `filter` alone stops the
  // tap being read as a drag but still leaves the button dead on touch.
  it("lets the filtered touch through so it still becomes a click", () => {
    renderEditor([cover()]);

    expect(sortableProps.current?.preventOnFilter).toBe(false);
  });

  // The filter selector has to actually match the button, or both options above are inert.
  it("marks the remove button with the attribute the filter selects on", () => {
    renderEditor([cover()]);

    const button = screen.getByLabelText("Remove cover");
    const filter = String(sortableProps.current?.filter);

    expect(button.matches(filter)).toBe(true);
  });
});
