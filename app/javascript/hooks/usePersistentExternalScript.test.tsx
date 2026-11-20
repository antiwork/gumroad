// @vitest-environment happy-dom
import { cleanup, fireEvent, renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";

import { usePersistentExternalScript } from "$app/hooks/usePersistentExternalScript";

const src = "https://example.com/widget.js";
const scripts = () => [...document.querySelectorAll<HTMLScriptElement>(`script[src="${src}"]`)];
afterEach(() => {
  vi.restoreAllMocks();
  cleanup();
  scripts().forEach((script) => script.remove());
});

it("retries a failed script on remount and preserves a successful script", () => {
  const append = document.body.appendChild.bind(document.body);
  vi.spyOn(document.body, "appendChild").mockImplementation((node) => {
    if (node instanceof HTMLScriptElement) node.type = "application/json";
    return append(node);
  });

  const first = renderHook(() => usePersistentExternalScript(src));
  const script = scripts()[0];
  if (!script) throw new Error("Expected the initial script");
  fireEvent.error(script);
  first.unmount();
  expect(scripts()).toHaveLength(0);

  const second = renderHook(() => usePersistentExternalScript(src));
  const retry = scripts()[0];
  if (!retry) throw new Error("Expected a new script");
  expect(retry).not.toBe(script);
  fireEvent.load(retry);
  second.unmount();
  renderHook(() => usePersistentExternalScript(src));
  expect(scripts()).toEqual([retry]);
});
