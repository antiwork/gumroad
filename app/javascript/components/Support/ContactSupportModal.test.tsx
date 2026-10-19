// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ContactSupportModal } from "$app/components/Support/ContactSupportModal";

vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));

const DRAFT_KEY = "gumroad:help-center:contact-draft";

const renderModal = () => render(<ContactSupportModal open onClose={() => {}} />);

const fillValidForm = () => {
  fireEvent.change(screen.getByLabelText("Your email"), { target: { value: "seller@example.com" } });
  fireEvent.change(screen.getByLabelText("What do you need help with?"), { target: { value: "technical issue" } });
  fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Checkout does nothing when I click it." } });
};

describe("ContactSupportModal", () => {
  beforeEach(() => {
    window.localStorage.clear();
    vi.stubGlobal("Routes", { help_center_contact_path: () => "/help/contact" });
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response(JSON.stringify({ success: true }), { status: 200 }))),
    );
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("restores an unsent draft and keeps it while the modal is closed", () => {
    window.localStorage.setItem(DRAFT_KEY, "Half-written report");

    renderModal();
    expect(screen.getByLabelText<HTMLTextAreaElement>("Message").value).toBe("Half-written report");

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Half-written report, finished" } });
    expect(window.localStorage.getItem(DRAFT_KEY)).toBe("Half-written report, finished");
  });

  it("clears the draft once the message has been sent", async () => {
    window.localStorage.setItem(DRAFT_KEY, "Half-written report");

    renderModal();
    fillValidForm();
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));

    await waitFor(() => expect(screen.getByText(/Message sent!/u)).not.toBeNull());
    expect(window.localStorage.getItem(DRAFT_KEY)).toBeNull();
  });

  it("lists a chosen screenshot so the user can see it will be sent", () => {
    renderModal();
    const screenshot = new File(["png"], "checkout.png", { type: "image/png" });

    fireEvent.change(screen.getByLabelText("Screenshots (optional)"), { target: { files: [screenshot] } });

    expect(screen.getByText(/checkout\.png/u)).not.toBeNull();
  });

  it("refuses a file that is not an image", () => {
    renderModal();
    const pdf = new File(["pdf"], "notes.pdf", { type: "application/pdf" });

    fireEvent.change(screen.getByLabelText("Screenshots (optional)"), { target: { files: [pdf] } });

    expect(screen.getByRole("alert").textContent).toContain("PNG, JPG, GIF or WEBP");
  });
});
