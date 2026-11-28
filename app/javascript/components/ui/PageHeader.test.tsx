// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { HeaderNavContext } from "$app/components/HeaderNavContext";
import { PageSlotsProvider, usePageSlotRefs } from "$app/components/PageSlots";
import { InHeaderNav, PageHeader, PlaceholderAction } from "$app/components/ui/PageHeader";
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

  it("leaves the actions of an empty page to its placeholder under the header nav", () => {
    const renderEmpty = (headerNav: boolean) =>
      render(
        <HeaderNavContext.Provider value={headerNav}>
          <PageHeader title="Sales" empty actions={<button type="button">Export</button>} />
          <PlaceholderAction>
            <a href="/products/new">Start selling</a>
          </PlaceholderAction>
        </HeaderNavContext.Provider>,
      );

    renderEmpty(false);
    expect(screen.getByRole("button", { name: "Export" })).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Start selling" })).toBeNull();
    cleanup();

    renderEmpty(true);
    expect(screen.queryByRole("button", { name: "Export" })).toBeNull();
    expect(screen.getByRole("link", { name: "Start selling" })).toBeTruthy();
  });

  it("keeps an action the header nav already offers for phones only", () => {
    const renderAction = (headerNav: boolean) =>
      render(
        <HeaderNavContext.Provider value={headerNav}>
          <InHeaderNav>
            <a href="/products/new">New product</a>
          </InHeaderNav>
        </HeaderNavContext.Provider>,
      );

    renderAction(false);
    expect(screen.getByRole("link", { name: "New product" })).toBeTruthy();
    cleanup();

    // A wide screen has it in the header; a phone's bar has no create button.
    renderAction(true);
    const wrapper = screen.getByRole("link", { name: "New product" }).parentElement;
    expect(wrapper?.className.split(" ")).toEqual(expect.arrayContaining(["contents", "lg:hidden"]));
    expect(wrapper?.hasAttribute("data-in-header-nav")).toBe(true);
  });

  it("puts a form page's buttons in the bar under the page, and keeps its title on a phone", () => {
    const Shell = () => {
      const refs = usePageSlotRefs();
      return (
        <>
          <PageHeader title="Figma UI kit" actions={<button type="button">Save changes</button>} />
          <footer ref={refs?.setFooter} />
        </>
      );
    };
    render(
      <PageSlotsProvider>
        <HeaderNavContext.Provider value>
          <Shell />
        </HeaderNavContext.Provider>
      </PageSlotsProvider>,
    );

    expect(screen.getByRole("button", { name: "Save changes" }).closest("footer")).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Figma UI kit" }).className).not.toContain("hidden!");
  });

  it("moves the tabs into the phone's menu below the wide breakpoint", () => {
    vi.stubGlobal("matchMedia", () => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
    const Shell = () => {
      const refs = usePageSlotRefs();
      return (
        <>
          <nav ref={refs?.setNavTabs} />
          <PageHeader title="Products">
            <Tabs>
              <Tab isSelected href="/products">
                All products
              </Tab>
            </Tabs>
          </PageHeader>
        </>
      );
    };
    render(
      <PageSlotsProvider>
        <HeaderNavContext.Provider value>
          <Shell />
        </HeaderNavContext.Provider>
      </PageSlotsProvider>,
    );

    const tab = screen.getByRole("tab", { name: "All products" });
    expect(tab.closest("nav")).toBeTruthy();
    expect(tab.className).toContain("font-bold");
    vi.unstubAllGlobals();
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
