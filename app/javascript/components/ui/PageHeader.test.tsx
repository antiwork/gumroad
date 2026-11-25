// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { HeaderNavContext } from "$app/components/HeaderNavContext";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

afterEach(cleanup);

const renderHeader = (headerNav: boolean, title: React.ReactNode = "Products") =>
  render(
    <HeaderNavContext.Provider value={headerNav}>
      <PageHeader title={title} actions={<button type="button">Export</button>}>
        <Tabs>
          <Tab isSelected href="/products">
            All products
          </Tab>
          <Tab isSelected={false} href="/products/affiliated">
            Affiliated
          </Tab>
        </Tabs>
      </PageHeader>
    </HeaderNavContext.Provider>,
  );

describe("PageHeader", () => {
  it("shows the title and pill tabs without the header nav", () => {
    renderHeader(false);

    expect(screen.getByRole("heading", { name: "Products" }).className).not.toContain("lg:sr-only!");
    expect(screen.getByRole("tab", { name: "All products" }).className).not.toContain("lg:font-bold");
  });

  it("keeps a section title for screen readers only under the header nav, which already names it", () => {
    renderHeader(true);

    expect(screen.getByRole("heading", { name: "Products" }).className).toContain("lg:sr-only!");
  });

  it("turns the tabs into text tabs under the header nav, with the selected one marked by more than colour", () => {
    renderHeader(true);

    const selected = screen.getByRole("tab", { name: "All products" });
    expect(selected.className).toContain("lg:font-bold");
    expect(selected.className).toContain("lg:shadow-[inset_0_-0.125rem_0_currentColor]!");
    expect(selected.getAttribute("aria-selected")).toBe("true");
    expect(screen.getByRole("tab", { name: "Affiliated" }).className).not.toContain("lg:font-bold");
  });

  it("keeps a title the header nav does not show, with the text tabs under it", () => {
    renderHeader(true, "The Works of Edgar Gumstein");

    expect(screen.getByRole("heading", { name: "The Works of Edgar Gumstein" }).className).not.toContain("lg:sr-only!");
    const selected = screen.getByRole("tab", { name: "All products" });
    expect(selected.className).toContain("lg:font-bold");
    expect(selected.className).toContain("lg:pb-4!");
    expect(selected.className).not.toContain("lg:py-5!");
  });
});
