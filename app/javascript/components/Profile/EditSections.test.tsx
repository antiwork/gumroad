// @vitest-environment happy-dom
//
// The profile editor's "Add section" menu builds and POSTs its own section, separate from the
// form's createSection path. A new products section has to carry the creator's catalog: an empty
// list matches no product, so the public section read "No products found" until products were
// picked by hand.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AddSectionButton, ReducerContext, type Action, type PageProps } from "$app/components/Profile/EditSections";

// Keep the popover's own open/close machinery out of a payload test, but merge the trigger's props
// (its aria-label) onto the child the way Radix's `asChild` slot does.
vi.mock("$app/components/Popover", () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>;
  const Trigger = ({
    children,
    asChild,
    ...rest
  }: { children: React.ReactElement; asChild?: boolean } & React.HTMLAttributes<HTMLElement>) => {
    void asChild;
    return React.cloneElement(children, rest);
  };
  return { Popover: Passthrough, PopoverContent: Passthrough, PopoverTrigger: Trigger };
});

const mocks = vi.hoisted(() => ({ request: vi.fn(), dispatch: vi.fn() }));
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request: mocks.request,
}));
vi.stubGlobal("Routes", { profile_sections_path: () => "/profile/sections" });

const pageProps = (): PageProps => ({
  currency_code: "usd",
  creator_profile: {
    external_id: "seller-1",
    avatar_url: "",
    name: "Creator",
    twitter_handle: null,
    subdomain: "creator.gumroad.com",
    is_verified: false,
    can_edit: true,
  },
  sections: [],
  products: [
    { id: "product-second", name: "Second product" },
    { id: "product-first", name: "First product" },
  ],
  posts: [],
  wishlist_options: [],
});

afterEach(cleanup);

describe("AddSectionButton", () => {
  it("posts a products section already carrying the creator's catalog, in order", async () => {
    const context: readonly [PageProps, React.Dispatch<Action>] = [pageProps(), mocks.dispatch];
    mocks.request.mockResolvedValue(new Response(JSON.stringify({ id: "section-1" }), { status: 200 }));
    render(
      <ReducerContext.Provider value={context}>
        <AddSectionButton index={0} />
      </ReducerContext.Provider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Add section" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Products" }));
    await waitFor(() => expect(mocks.request).toHaveBeenCalled());

    expect(mocks.request).toHaveBeenCalledWith({
      method: "POST",
      url: "/profile/sections",
      data: expect.objectContaining({
        type: "SellerProfileProductsSection",
        shown_products: ["product-second", "product-first"],
      }),
      accept: "json",
    });
  });
});
