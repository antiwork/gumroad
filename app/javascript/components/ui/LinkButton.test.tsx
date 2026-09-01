// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { LinkButton } from "$app/components/ui/LinkButton";

afterEach(cleanup);

// happy-dom does not implement Enter-to-submit, so the default-button set is what catches the
// regression here. The browser-level behaviour lives in spec/requests/settings/main_spec.rb.
const defaultButtonsOf = (form: HTMLElement) =>
  form.querySelectorAll('button:not([type="button"]):not([type="reset"]), input[type="submit"]');

describe("LinkButton", () => {
  it("renders type=button so it never becomes a form's default submit button", () => {
    render(<LinkButton>Switch to direct deposit</LinkButton>);

    expect(screen.getByRole("button", { name: "Switch to direct deposit" }).getAttribute("type")).toBe("button");
  });

  it("leaves a form containing it with no default submit button", () => {
    render(
      <form aria-label="Payouts">
        <input type="text" aria-label="PayPal email" />
        <LinkButton>Switch to direct deposit</LinkButton>
      </form>,
    );

    expect(defaultButtonsOf(screen.getByRole("form", { name: "Payouts" }))).toHaveLength(0);
  });

  it("keeps the link styling and merges a call site's own classes", () => {
    render(<LinkButton className="w-max self-start text-sm">Close</LinkButton>);

    const button = screen.getByRole("button", { name: "Close" });
    expect(button.className).toContain("all-unset");
    expect(button.className).toContain("underline");
    expect(button.className).toContain("cursor-pointer");
    expect(button.className).toContain("w-max");
    expect(button.className).toContain("self-start");
    expect(button.className).toContain("text-sm");
  });

  it("forwards a ref to the underlying button", () => {
    const ref = React.createRef<HTMLButtonElement>();
    render(<LinkButton ref={ref}>Edit</LinkButton>);

    expect(ref.current).toBe(screen.getByRole("button", { name: "Edit" }));
  });
});
