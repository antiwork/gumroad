// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";

afterEach(cleanup);

const user = { name: "Ada", email: "ada@example.com", avatarUrl: "" };
const renderMenu = () => {
  render(
    <DashboardNavProfilePopover user={user}>
      <a role="menuitemradio" aria-checked="false" href="#switch">
        Other account
      </a>
      <a role="menuitem" href="#settings">
        Settings
      </a>
    </DashboardNavProfilePopover>,
  );
  fireEvent.click(screen.getByRole("button", { name: /Ada/u }));
};

describe("DashboardNavProfilePopover", () => {
  it("closes once a destination is chosen", () => {
    renderMenu();

    fireEvent.click(screen.getByRole("menuitem", { name: "Settings" }));

    expect(screen.queryByRole("menuitem", { name: "Settings" })).toBeNull();
  });

  // Switching accounts reloads the page; closing first hid the choice while the request was out.
  it("stays open while an account switch is under way", () => {
    renderMenu();

    fireEvent.click(screen.getByRole("menuitemradio", { name: "Other account" }));

    expect(screen.getByRole("menuitemradio", { name: "Other account" })).toBeTruthy();
  });
});
