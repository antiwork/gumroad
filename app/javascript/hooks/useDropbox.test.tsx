// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const API_KEY = "test-app-key";
const DROPINS_URL = "https://www.dropbox.com/static/api/2/dropins.js";

const appended: HTMLScriptElement[] = [];
const rendered: (() => void)[] = [];

const requestedScript = (index = 0) => {
  const script = appended[index];
  if (!script) throw new Error(`no dropins script was requested at index ${index}`);
  return script;
};

// The hook caches its load in module state, so each test needs its own copy of the module — and of
// React, which has to be the same copy the module holds or the effect would never run.
const mount = async (apiKey: string | null = API_KEY) => {
  const [react, { render }, { useDropbox }] = await Promise.all([
    import("react"),
    import("@testing-library/react"),
    import("./useDropbox"),
  ]);

  const Harness = () => {
    useDropbox(apiKey);
    return null;
  };

  rendered.push(render(react.createElement(Harness)).unmount);
};

beforeEach(() => {
  vi.resetModules();
  appended.length = 0;
  rendered.length = 0;
  document.querySelectorAll("#dropboxjs").forEach((element) => element.remove());

  // happy-dom cannot load an external script, and these tests drive the tag's events themselves.
  // Each entry is one request the browser would have made.
  const appendChild = document.body.appendChild.bind(document.body);
  vi.spyOn(document.body, "appendChild").mockImplementation((node: Node) => {
    if (node instanceof HTMLScriptElement) {
      node.type = "application/json";
      appended.push(node);
    }
    return appendChild(node);
  });
});

afterEach(() => {
  rendered.forEach((unmount) => unmount());
  vi.restoreAllMocks();
});

describe("useDropbox", () => {
  it("requests the dropins script for the page's api key", async () => {
    await mount();

    expect(appended).toHaveLength(1);
    expect(requestedScript().src).toBe(DROPINS_URL);
    expect(requestedScript().getAttribute("data-app-key")).toBe(API_KEY);
  });

  it("requests the script once when several mounts ask for it together", async () => {
    await mount();
    await mount();

    expect(appended).toHaveLength(1);
  });

  it("requests the script again on the next mount after a failed load", async () => {
    await mount();
    requestedScript().dispatchEvent(new Event("error"));

    expect(requestedScript().isConnected).toBe(false);
    expect(document.getElementById("dropboxjs")).toBeNull();

    rendered.splice(0).forEach((unmount) => unmount());
    await mount();

    expect(appended).toHaveLength(2);
    expect(requestedScript(1).src).toBe(DROPINS_URL);
    expect(requestedScript(1).isConnected).toBe(true);
  });

  it("keeps a script that loaded, so a later mount reuses it", async () => {
    await mount();
    requestedScript().dispatchEvent(new Event("load"));

    rendered.splice(0).forEach((unmount) => unmount());
    await mount();

    expect(appended).toHaveLength(1);
    expect(requestedScript().isConnected).toBe(true);
  });

  it("installs nothing without an api key", async () => {
    await mount(null);

    expect(appended).toHaveLength(0);
  });
});
