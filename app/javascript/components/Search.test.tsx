// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Search, normalizeSearchQuery } from "$app/components/Search";

afterEach(cleanup);

// The input lives inside a popover that only mounts once the trigger is clicked, so every UI test
// has to open it first.
const openSearch = () => {
  fireEvent.click(screen.getByRole("button", { name: "Toggle Search" }));
  const input = screen.getByRole("textbox");
  if (!(input instanceof HTMLInputElement)) throw new Error("expected the search field to be an <input>");
  return input;
};

describe("normalizeSearchQuery", () => {
  it("strips a pasted mailto: prefix", () => {
    expect(normalizeSearchQuery("mailto:someone@example.com")).toBe("someone@example.com");
  });

  it("strips the mailto:// variant", () => {
    expect(normalizeSearchQuery("mailto://someone@example.com")).toBe("someone@example.com");
  });

  it("ignores the case of the scheme and any leading whitespace", () => {
    expect(normalizeSearchQuery("  MailTo:someone@example.com")).toBe("someone@example.com");
  });

  it("percent-decodes the address, since mailto links are URLs", () => {
    expect(normalizeSearchQuery("mailto:some%20one%40example.com")).toBe("some one@example.com");
  });

  it("drops mailto parameters such as ?subject=", () => {
    expect(normalizeSearchQuery("mailto:someone@example.com?subject=Refund%20please")).toBe("someone@example.com");
  });

  it("keeps the pasted text when it contains a malformed percent escape", () => {
    expect(normalizeSearchQuery("mailto:100%@example.com")).toBe("100%@example.com");
  });

  it("leaves an ordinary query untouched, including its whitespace", () => {
    expect(normalizeSearchQuery("someone@example.com")).toBe("someone@example.com");
    expect(normalizeSearchQuery("Jane ")).toBe("Jane ");
    expect(normalizeSearchQuery("")).toBe("");
  });

  it("does not strip a mailto: that is not at the start", () => {
    expect(normalizeSearchQuery("about mailto:links")).toBe("about mailto:links");
  });

  it("keeps a plus-addressed alias intact", () => {
    expect(normalizeSearchQuery("mailto:jane+shop@example.com")).toBe("jane+shop@example.com");
  });

  it("leaves nothing behind when the link carries no address", () => {
    expect(normalizeSearchQuery("mailto:")).toBe("");
  });
});

describe("Search", () => {
  it("searches for the bare address when a mailto: link is pasted", () => {
    const onSearch = vi.fn();
    render(<Search value="" onSearch={onSearch} placeholder="Search sales" />);

    const input = openSearch();
    fireEvent.change(input, { target: { value: "mailto:someone@example.com" } });

    expect(onSearch).toHaveBeenLastCalledWith("someone@example.com");
    // The field shows the cleaned-up value, so the seller can see what is being searched for.
    expect(input.value).toBe("someone@example.com");
  });

  it("passes a normally typed query through unchanged", () => {
    const onSearch = vi.fn();
    render(<Search value="" onSearch={onSearch} placeholder="Search sales" />);

    const input = openSearch();
    fireEvent.change(input, { target: { value: "Jane" } });

    expect(onSearch).toHaveBeenLastCalledWith("Jane");
    expect(input.value).toBe("Jane");
  });

  it("does not eat characters while a query is typed one key at a time", () => {
    const onSearch = vi.fn();
    render(<Search value="" onSearch={onSearch} placeholder="Search sales" />);

    // Normalizing on every keystroke would be a problem if it could truncate a query mid-typing,
    // so walk a name through character by character the way a real seller types it.
    const input = openSearch();
    let typed = "";
    for (const character of "Jane Cooper") {
      typed += character;
      fireEvent.change(input, { target: { value: typed } });
      expect(input.value).toBe(typed);
    }

    expect(onSearch).toHaveBeenLastCalledWith("Jane Cooper");
  });
});
