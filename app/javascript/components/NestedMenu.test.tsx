// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { NestedMenu } from "$app/components/NestedMenu";
import { useIsOnTouchDevice } from "$app/components/useIsOnTouchDevice";

vi.mock("$app/components/CurrentSeller", () => ({ useCurrentSeller: () => ({ id: "seller" }) }));
vi.mock("$app/components/useIsOnTouchDevice", () => ({ useIsOnTouchDevice: vi.fn() }));

afterEach(cleanup);

const items = [
  { key: "audio", label: "Audio", href: "/discover/audio" },
  { key: "music", label: "Music", href: "/discover/audio/music", parentKey: "audio" },
];

it.each([false, true])("leaves Command-click on a category to the browser when touch=%s", (touch) => {
  vi.mocked(useIsOnTouchDevice).mockReturnValue(touch);
  const onSelectItem = vi.fn();
  render(<NestedMenu type="menubar" items={items} onSelectItem={onSelectItem} />);

  const category = screen.getByRole("menuitem", { name: "Audio" });
  expect(fireEvent.click(category, { metaKey: true })).toBe(true);
  expect(onSelectItem).not.toHaveBeenCalled();

  expect(fireEvent.click(category)).toBe(false);
  expect(onSelectItem).toHaveBeenCalledTimes(touch ? 0 : 1);
});
