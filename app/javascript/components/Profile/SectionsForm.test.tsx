// @vitest-environment happy-dom
//
// Covers the three profile-section-editor gaps a seller reported after building a four-tab profile
// (gumroad-private#1714): a section could only be rebuilt by hand, a named section's row showed its
// heading with nothing tying it to the kind of block it labels, and a new subscribe section arrived
// with pre-filled copy that reads as intentional while every other section type starts blank.
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { type Section } from "$app/components/Profile/EditSections";
import { ProfileSectionsForm, type ProfileSectionsFormProps } from "$app/components/Profile/SectionsForm";

type FormState = Parameters<NonNullable<ProfileSectionsFormProps["onChange"]>>[0];

// A rich text section mounts UpsellSelectModal, which fetches its product list on mount. Both the
// route helper and the fetch have to exist or vitest reports the rejection as an unhandled error
// and fails the whole run, even though every assertion passed.
vi.stubGlobal("Routes", {
  root_url: () => "https://creator.gumroad.com/",
  checkout_upsells_products_path: () => "/checkout/upsells/products",
});
vi.stubGlobal("fetch", () =>
  Promise.resolve(new Response("[]", { status: 200, headers: { "Content-Type": "application/json" } })),
);
// `SSR` is a vite `define`, so it does not exist under vitest; RichTextEditor reads it at render.
vi.stubGlobal("SSR", false);

const props = (): ProfileSectionsFormProps => ({
  bio: null,
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
  tabs: [{ name: "Home", sections: ["section-1"] }],
  sections: [
    {
      id: "section-1",
      type: "SellerProfilePostsSection",
      header: "About me",
      hide_header: false,
      shown_posts: [],
    },
  ],
  products: [],
  posts: [],
  wishlist_options: [],
});

const sectionRows = () => within(screen.getByRole("list", { name: "Sections" })).getAllByRole("listitem");

const firstRow = () => assertDefined(sectionRows()[0]);

const trackState = () => {
  const states: FormState[] = [];
  return {
    onChange: (state: FormState) => void states.push(state),
    latest: () => assertDefined(states.at(-1)),
  };
};

afterEach(cleanup);

describe("ProfileSectionsForm", () => {
  it("duplicates a section directly below the original without touching the original", () => {
    const tracked = trackState();
    render(<ProfileSectionsForm {...props()} onChange={tracked.onChange} />);

    fireEvent.click(screen.getByRole("button", { name: "Duplicate section" }));

    const rows = sectionRows();
    expect(rows).toHaveLength(2);
    for (const row of rows) expect(within(row).getByRole("heading", { level: 3 }).textContent).toBe("About me");

    const state = tracked.latest();
    const [originalId, copyId] = assertDefined(state.tabs[0]).sections;
    expect(originalId).toBe("section-1");
    expect(copyId).not.toBe("section-1");
    // The copy carries the original's content; only its identity differs, so saving it creates a
    // second section rather than overwriting the one it was copied from.
    expect(state.sections.find(({ id }) => id === copyId)).toMatchObject({
      type: "SellerProfilePostsSection",
      header: "About me",
    });
  });

  it("inserts the copy after the section it came from, not at the end of the page", () => {
    const withThree = props();
    withThree.tabs = [{ name: "Home", sections: ["section-1", "section-2"] }];
    withThree.sections = [
      ...withThree.sections,
      { id: "section-2", type: "SellerProfilePostsSection", header: "Contact", hide_header: false, shown_posts: [] },
    ];
    const tracked = trackState();
    render(<ProfileSectionsForm {...withThree} onChange={tracked.onChange} />);

    fireEvent.click(assertDefined(screen.getAllByRole("button", { name: "Duplicate section" })[0]));

    const ids = assertDefined(tracked.latest().tabs[0]).sections;
    expect(ids[0]).toBe("section-1");
    expect(ids[2]).toBe("section-2");
  });

  it("names the section type alongside a custom heading so the row says what it labels", () => {
    render(<ProfileSectionsForm {...props()} />);

    const row = firstRow();
    expect(within(row).getByRole("heading", { level: 3 }).textContent).toBe("About me");
    expect(row.querySelector("h3 + small")?.textContent).toBe("Posts");
  });

  it("does not repeat the type when the heading is already the type name", () => {
    const unnamed = props();
    unnamed.sections = [{ ...assertDefined(unnamed.sections[0]), header: "" }];
    render(<ProfileSectionsForm {...unnamed} />);

    expect(within(firstRow()).getByRole("heading", { level: 3 }).textContent).toBe("Posts");
    expect(firstRow().querySelector("h3 + small")).toBeNull();
  });

  it("gives a duplicated rich text section its own upsell cards", () => {
    const withUpsell = props();
    withUpsell.sections = [
      {
        id: "section-1",
        type: "SellerProfileRichTextSection",
        header: "Pitch",
        hide_header: false,
        text: {
          content: [
            { type: "upsellCard", attrs: { id: "upsell-1", productId: "prod-1" } },
            { type: "paragraph", attrs: { id: "keep-me" } },
          ],
        },
      },
    ];
    const tracked = trackState();
    render(<ProfileSectionsForm {...withUpsell} onChange={tracked.onChange} />);

    fireEvent.click(screen.getByRole("button", { name: "Duplicate section" }));

    const nodes = (section: Section): unknown[] => {
      if (section.type !== "SellerProfileRichTextSection") throw new Error("expected a rich text section");
      const content: unknown = section.text.content;
      if (!Array.isArray(content)) throw new Error("expected rich text content");
      return content;
    };

    const state = tracked.latest();
    // The card keeps everything the server needs to mint a replacement upsell; only the id of the
    // original's Upsell row is dropped, and only on the copy.
    const copied = nodes(assertDefined(state.sections.find(({ id }) => id !== "section-1")));
    expect(copied[0]).toEqual({ type: "upsellCard", attrs: { productId: "prod-1" } });
    expect(copied[1]).toEqual({ type: "paragraph", attrs: { id: "keep-me" } });
    expect(nodes(assertDefined(state.sections.find(({ id }) => id === "section-1")))[0]).toEqual({
      type: "upsellCard",
      attrs: { id: "upsell-1", productId: "prod-1" },
    });
  });

  it("creates a subscribe section with an empty heading like every other section type", () => {
    const empty = props();
    empty.tabs = [{ name: "Home", sections: [] }];
    empty.sections = [];
    const tracked = trackState();
    render(<ProfileSectionsForm {...empty} onChange={tracked.onChange} />);

    fireEvent.click(screen.getByRole("button", { name: "Add section" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Subscribe" }));

    expect(tracked.latest().sections[0]).toMatchObject({
      type: "SellerProfileSubscribeSection",
      header: "",
      button_label: "Subscribe",
    });
  });
});
