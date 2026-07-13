import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { loadAcknowledgedEmails, persistAcknowledgedEmail } from "$app/components/Checkout/acknowledgedEmails";

// Vitest runs in a node environment with no localStorage, so install a minimal in-memory
// implementation that behaves like the browser API for these tests.
const installLocalStorage = () => {
  const store = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => store.set(key, value),
    removeItem: (key: string) => store.delete(key),
    clear: () => store.clear(),
  });
  return store;
};

describe("acknowledgedEmails persistence", () => {
  beforeEach(() => {
    installLocalStorage();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns an empty set when nothing has been stored", () => {
    expect(loadAcknowledgedEmails().size).toBe(0);
  });

  it("remembers a dismissed email across loads", () => {
    persistAcknowledgedEmail("kevin@hoge.land");
    expect(loadAcknowledgedEmails().has("kevin@hoge.land")).toBe(true);
  });

  it("keeps multiple dismissed emails", () => {
    persistAcknowledgedEmail("a@example.land");
    persistAcknowledgedEmail("b@example.dev");
    const emails = loadAcknowledgedEmails();
    expect(emails.has("a@example.land")).toBe(true);
    expect(emails.has("b@example.dev")).toBe(true);
  });

  it("does not duplicate an email dismissed twice", () => {
    persistAcknowledgedEmail("a@example.land");
    persistAcknowledgedEmail("a@example.land");
    expect(loadAcknowledgedEmails().size).toBe(1);
  });

  it("caps the stored list, evicting the oldest entries first", () => {
    for (let i = 0; i < 60; i++) persistAcknowledgedEmail(`buyer${i}@example.com`);
    const emails = loadAcknowledgedEmails();
    expect(emails.size).toBe(50);
    expect(emails.has("buyer0@example.com")).toBe(false);
    expect(emails.has("buyer59@example.com")).toBe(true);
  });

  it("ignores corrupted stored data instead of throwing", () => {
    localStorage.setItem("gr_checkout_acknowledged_emails", "not json {{");
    expect(loadAcknowledgedEmails().size).toBe(0);

    localStorage.setItem("gr_checkout_acknowledged_emails", JSON.stringify({ nope: true }));
    expect(loadAcknowledgedEmails().size).toBe(0);
  });

  it("degrades gracefully when localStorage is unavailable", () => {
    vi.unstubAllGlobals();
    // No localStorage in this node environment at all — both calls must not throw.
    expect(loadAcknowledgedEmails().size).toBe(0);
    expect(() => persistAcknowledgedEmail("a@example.com")).not.toThrow();
  });
});
