// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ContactSupportModal } from "$app/components/Support/ContactSupportModal";

const session = vi.hoisted((): { userId: string | null } => ({ userId: null }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () =>
    session.userId === null ? null : { id: session.userId, email: `account-${session.userId}@example.com` },
}));

const MB = 1024 * 1024;

const draftKey = (userId: string | null) => `gumroad:help-center:contact-draft:${userId ?? "anonymous"}`;

const modal = () => <ContactSupportModal open onClose={() => {}} />;
const renderModal = () => render(modal());

// Mirrors the Help Center header: the modal stays mounted while it is closed.
const WithTrigger = () => {
  const [open, setOpen] = React.useState(true);
  return (
    <>
      <button onClick={() => setOpen(true)}>Open contact form</button>
      <ContactSupportModal open={open} onClose={() => setOpen(false)} />
    </>
  );
};

const closeAndReopen = () => {
  const [close] = screen.getAllByRole("button", { name: "Close" });
  if (!close) throw new Error("no close button");
  fireEvent.click(close);
  expect(screen.queryByLabelText("Message")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Open contact form" }));
};

const messageField = () => screen.getByLabelText<HTMLTextAreaElement>("Message");
const emailField = () => screen.getByLabelText<HTMLInputElement>("Your email");
const attach = (...files: File[]) =>
  fireEvent.change(screen.getByLabelText("Screenshots (optional)"), { target: { files } });
const image = (name: string, bytes: number[] | number = [0x89, 0x50, 0x4e, 0x47], type = "image/png") =>
  new File([typeof bytes === "number" ? new Uint8Array(bytes) : Uint8Array.from(bytes)], name, { type });
const listed = (name: string) => screen.queryAllByText(new RegExp(`^${name.replace(".", "\\.")} \\(`, "u"));

const fillValidForm = () => {
  fireEvent.change(emailField(), { target: { value: "buyer@example.com" } });
  fireEvent.change(screen.getByLabelText("What do you need help with?"), { target: { value: "technical issue" } });
  fireEvent.change(messageField(), { target: { value: "Checkout does nothing when I click it." } });
};
const send = () => fireEvent.click(screen.getByRole("button", { name: "Send message" }));

const jsonResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

const editableControls = () => [
  emailField(),
  screen.getByLabelText<HTMLSelectElement>("What do you need help with?"),
  messageField(),
  screen.getByLabelText<HTMLInputElement>("Screenshots (optional)"),
  ...screen.getAllByRole<HTMLButtonElement>("button", { name: "Remove" }),
];

const sentFields = async (body: BodyInit | null | undefined) => {
  if (!(body instanceof FormData)) throw new Error("expected a multipart body");
  const files = await Promise.all(
    body.getAll("attachments[]").map(async (file) => {
      if (!(file instanceof File)) throw new Error("expected a file part");
      return [file.name, [...new Uint8Array(await file.arrayBuffer())]];
    }),
  );
  return { email: body.get("email"), category: body.get("category"), message: body.get("message"), files };
};

describe("ContactSupportModal", () => {
  let fetchMock: ReturnType<typeof vi.fn<typeof fetch>>;

  beforeEach(() => {
    window.localStorage.clear();
    window.sessionStorage.clear();
    session.userId = null;
    vi.stubGlobal("Routes", { help_center_contact_path: () => "/help/contact" });
    fetchMock = vi.fn<typeof fetch>(() => Promise.resolve(jsonResponse({ success: true })));
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  describe("draft", () => {
    it("keeps the message and screenshots when the modal is closed and opened again", () => {
      render(<WithTrigger />);
      fireEvent.change(messageField(), { target: { value: "Half-written report" } });
      attach(image("checkout.png"));

      closeAndReopen();

      expect(messageField().value).toBe("Half-written report");
      expect(listed("checkout.png")).toHaveLength(1);
    });

    it("restores the unsent message after a reload of the same tab", () => {
      renderModal();
      fireEvent.change(messageField(), { target: { value: "Half-written report" } });
      cleanup();

      renderModal();

      expect(messageField().value).toBe("Half-written report");
    });

    it("keeps the draft to this tab instead of the browser's long-lived storage", () => {
      renderModal();
      fireEvent.change(messageField(), { target: { value: "Anonymous visitor's report" } });

      expect(window.sessionStorage.getItem(draftKey(null))).toBe("Anonymous visitor's report");
      expect(window.localStorage.getItem(draftKey(null))).toBeNull();
    });

    it("discards drafts an earlier version left in localStorage without showing them", () => {
      window.localStorage.setItem(draftKey(null), "Someone else's anonymous draft");
      window.localStorage.setItem(draftKey("1"), "Account one's old draft");
      window.localStorage.setItem("unrelated", "kept");

      renderModal();

      expect(messageField().value).toBe("");
      expect(window.localStorage.getItem(draftKey(null))).toBeNull();
      expect(window.localStorage.getItem(draftKey("1"))).toBeNull();
      expect(window.localStorage.getItem("unrelated")).toBe("kept");
    });

    it("does not hand one account's draft to another account on the same browser", () => {
      session.userId = "1";
      renderModal();
      fireEvent.change(messageField(), { target: { value: "Draft written by account one" } });
      expect(window.sessionStorage.getItem(draftKey("1"))).toBe("Draft written by account one");
      cleanup();

      session.userId = "2";
      renderModal();
      expect(messageField().value).toBe("");
      cleanup();

      session.userId = null;
      renderModal();
      expect(messageField().value).toBe("");
      expect(window.sessionStorage.getItem(draftKey("1"))).toBe("Draft written by account one");
    });

    it("starts over without touching other drafts when the account changes while mounted", () => {
      session.userId = "1";
      const { rerender } = render(modal());
      expect(emailField().value).toBe("account-1@example.com");
      fireEvent.change(messageField(), { target: { value: "Draft written by account one" } });
      attach(image("one.png"));

      session.userId = "2";
      rerender(modal());
      expect(messageField().value).toBe("");
      expect(emailField().value).toBe("account-2@example.com");
      expect(listed("one.png")).toHaveLength(0);
      expect(window.sessionStorage.getItem(draftKey("1"))).toBe("Draft written by account one");
      expect(window.sessionStorage.getItem(draftKey("2"))).toBeNull();

      fireEvent.change(messageField(), { target: { value: "Draft written by account two" } });
      session.userId = null;
      rerender(modal());
      expect(messageField().value).toBe("");
      expect(emailField().value).toBe("");
      expect(window.sessionStorage.getItem(draftKey("2"))).toBe("Draft written by account two");
      expect(window.sessionStorage.getItem(draftKey(null))).toBeNull();

      session.userId = "1";
      rerender(modal());
      expect(messageField().value).toBe("Draft written by account one");
      expect(window.sessionStorage.getItem(draftKey(null))).toBeNull();
    });

    it("still sends when the browser blocks storage", async () => {
      const blocked = () => {
        throw new DOMException("Storage is disabled", "SecurityError");
      };
      vi.spyOn(Storage.prototype, "getItem").mockImplementation(blocked);
      vi.spyOn(Storage.prototype, "setItem").mockImplementation(blocked);
      vi.spyOn(Storage.prototype, "removeItem").mockImplementation(blocked);
      vi.spyOn(Storage.prototype, "key").mockImplementation(blocked);

      renderModal();
      fillValidForm();
      send();

      await waitFor(() => expect(screen.getByText(/Message sent!/u)).not.toBeNull());
    });
  });

  describe("screenshots", () => {
    it("lists a chosen screenshot so the user can see it will be sent", () => {
      renderModal();

      attach(image("checkout.png"));

      expect(listed("checkout.png")).toHaveLength(1);
    });

    it("lets a removed screenshot be chosen again", () => {
      renderModal();
      const screenshot = image("checkout.png");
      attach(screenshot);

      fireEvent.click(screen.getByRole("button", { name: "Remove" }));
      expect(listed("checkout.png")).toHaveLength(0);

      attach(screenshot);
      expect(listed("checkout.png")).toHaveLength(1);
    });

    it("attaches a screenshot pasted into the message", () => {
      renderModal();

      fireEvent.paste(messageField(), { clipboardData: { files: [image("image.png")], getData: () => "" } });

      expect(listed("image.png")).toHaveLength(1);
    });

    it("lets copied text paste as usual when the clipboard also carries an image", () => {
      renderModal();

      const notPrevented = fireEvent.paste(messageField(), {
        clipboardData: {
          files: [image("image.png")],
          getData: (type: string) => (type === "text/plain" ? "Order 1234 was charged twice" : ""),
        },
      });

      expect(notPrevented).toBe(true);
      expect(listed("image.png")).toHaveLength(1);
    });

    it("refuses a file that is not an image", () => {
      renderModal();

      attach(new File(["pdf"], "notes.pdf", { type: "application/pdf" }));

      expect(screen.getByRole("alert").textContent).toContain("PNG, JPG, GIF or WEBP");
      expect(listed("notes.pdf")).toHaveLength(0);
    });

    it("refuses a fourth screenshot", () => {
      renderModal();
      attach(image("a.png"), image("b.png"), image("c.png"));

      attach(image("d.png"));

      expect(screen.getByRole("alert").textContent).toBe("Please attach at most 3 images.");
      expect(listed("d.png")).toHaveLength(0);
      expect(screen.getAllByRole("button", { name: "Remove" })).toHaveLength(3);
    });

    it("refuses a screenshot over 3 MB", () => {
      renderModal();

      attach(image("huge.png", 3 * MB + 1));

      expect(screen.getByRole("alert").textContent).toBe("Each image must be smaller than 3.0 MB.");
      expect(listed("huge.png")).toHaveLength(0);
    });

    it("refuses screenshots that together pass 6 MB", () => {
      renderModal();

      attach(image("a.png", 2 * MB + 1), image("b.png", 2 * MB + 1), image("c.png", 2 * MB + 1));

      expect(screen.getByRole("alert").textContent).toBe("Attachments must total less than 6.0 MB.");
      expect(screen.queryAllByRole("button", { name: "Remove" })).toHaveLength(0);
    });
  });

  describe("sending", () => {
    // Holds the request open so the test can look at the form mid-send.
    const deferSend = () => {
      let respond: (response: Response) => void = () => {};
      fetchMock.mockImplementation(
        () =>
          new Promise<Response>((resolve) => {
            respond = resolve;
          }),
      );
      return (response: Response) => respond(response);
    };

    it("locks every field while sending, then clears exactly the draft that was sent", async () => {
      const respond = deferSend();
      render(<WithTrigger />);
      fillValidForm();
      attach(image("checkout.png", [0x89, 0x50, 0x4e, 0x47, 9]));

      send();
      await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
      expect(editableControls().map((control) => control.disabled)).toEqual([true, true, true, true, true]);
      fireEvent.click(screen.getByRole("button", { name: "Remove" }));
      expect(listed("checkout.png")).toHaveLength(1);

      expect(await sentFields(fetchMock.mock.calls[0]?.[1]?.body)).toEqual({
        email: "buyer@example.com",
        category: "technical issue",
        message: "Checkout does nothing when I click it.",
        files: [["checkout.png", [0x89, 0x50, 0x4e, 0x47, 9]]],
      });

      respond(jsonResponse({ success: true }));
      await waitFor(() => expect(screen.getByText(/Message sent!/u)).not.toBeNull());
      expect(window.sessionStorage.getItem(draftKey(null))).toBeNull();
      closeAndReopen();
      expect(messageField().value).toBe("");
      expect(listed("checkout.png")).toHaveLength(0);
    });

    it("unlocks the fields with everything intact when the server refuses the message", async () => {
      const respond = deferSend();
      renderModal();
      fillValidForm();
      attach(image("checkout.png"));

      send();
      await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
      respond(jsonResponse({ success: false, error: "Please select a category." }, 422));

      await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Please select a category."));
      expect(editableControls().map((control) => control.disabled)).toEqual([false, false, false, false, false]);
      expect(messageField().value).toBe("Checkout does nothing when I click it.");
      expect(listed("checkout.png")).toHaveLength(1);
    });

    it("posts the message with every screenshot byte", async () => {
      renderModal();
      fillValidForm();
      attach(
        image("image.png", [0x89, 0x50, 0x4e, 0x47, 1, 2, 3]),
        image("photo.jpg", [0xff, 0xd8, 0xff, 4], "image/jpeg"),
      );

      send();

      await waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
      const [url, init] = fetchMock.mock.calls[0] ?? [];
      expect(url).toBe("/help/contact");
      const body = init?.body;
      if (!(body instanceof FormData)) throw new Error("expected a multipart body");
      expect(body.get("message")).toBe("Checkout does nothing when I click it.");
      const sent = await Promise.all(
        body.getAll("attachments[]").map(async (file) => {
          if (!(file instanceof File)) throw new Error("expected a file part");
          return [file.name, [...new Uint8Array(await file.arrayBuffer())]];
        }),
      );
      expect(sent).toEqual([
        ["image.png", [0x89, 0x50, 0x4e, 0x47, 1, 2, 3]],
        ["photo.jpg", [0xff, 0xd8, 0xff, 4]],
      ]);
    });

    it("clears the draft and screenshots once the message has been sent", async () => {
      render(<WithTrigger />);
      fillValidForm();
      attach(image("checkout.png"));

      send();
      await waitFor(() => expect(screen.getByText(/Message sent!/u)).not.toBeNull());
      expect(window.sessionStorage.getItem(draftKey(null))).toBeNull();

      closeAndReopen();
      expect(messageField().value).toBe("");
      expect(listed("checkout.png")).toHaveLength(0);
    });

    it("keeps everything when the server refuses the message", async () => {
      fetchMock.mockResolvedValue(jsonResponse({ success: false, error: "Please select a category." }, 422));
      renderModal();
      fillValidForm();
      attach(image("checkout.png"));

      send();

      await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Please select a category."));
      expect(messageField().value).toBe("Checkout does nothing when I click it.");
      expect(listed("checkout.png")).toHaveLength(1);
      expect(window.sessionStorage.getItem(draftKey(null))).toBe("Checkout does nothing when I click it.");
    });

    it("keeps everything when the request never reaches the server", async () => {
      fetchMock.mockRejectedValue(new TypeError("Failed to fetch"));
      renderModal();
      fillValidForm();
      attach(image("checkout.png"));

      send();

      await waitFor(() => expect(screen.getByRole("alert")).not.toBeNull());
      expect(messageField().value).toBe("Checkout does nothing when I click it.");
      expect(listed("checkout.png")).toHaveLength(1);
      expect(window.sessionStorage.getItem(draftKey(null))).toBe("Checkout does nothing when I click it.");
    });
  });
});
