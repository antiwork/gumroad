// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Modal } from "$app/components/Modal";

afterEach(cleanup);

const ModalOpenedByButton = ({ onCloseAutoFocus }: { onCloseAutoFocus?: (event: Event) => void }) => {
  const [open, setOpen] = React.useState(false);
  return (
    <>
      <button onClick={() => setOpen(true)}>Open</button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Details"
        {...(onCloseAutoFocus ? { onCloseAutoFocus } : {})}
      >
        Body
      </Modal>
    </>
  );
};

describe("Modal", () => {
  it("hands focus to whatever onCloseAutoFocus picks when it closes", async () => {
    render(
      <ModalOpenedByButton
        onCloseAutoFocus={(event) => {
          event.preventDefault();
          screen.getByRole("button", { name: "Open" }).focus();
        }}
      />,
    );
    const opener = screen.getByRole("button", { name: "Open" });
    opener.focus();
    fireEvent.click(opener);
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });

    expect(screen.queryByRole("dialog")).toBeNull();
    await waitFor(() => expect(document.activeElement).toBe(opener));
  });

  it("leaves focus to Radix when no onCloseAutoFocus is given", async () => {
    render(<ModalOpenedByButton />);
    const opener = screen.getByRole("button", { name: "Open" });
    opener.focus();
    fireEvent.click(opener);
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });

    expect(screen.queryByRole("dialog")).toBeNull();
    // Without a Dialog.Trigger, Radix has nothing to restore to.
    await waitFor(() => expect(document.activeElement).toBe(document.body));
  });
});
