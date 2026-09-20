// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ConfirmBalanceForfeitOnPayoutMethodChangeModal } from "$app/components/ConfirmBalanceForfeitOnPayoutMethodChangeModal";

const onClose = vi.fn();
const onConfirm = vi.fn();

const renderModal = (
  props: { balance?: string | null; losesBankRail?: boolean; bankAccountNumberVisual?: string | null } = {},
) => {
  const { balance = null, losesBankRail = false, bankAccountNumberVisual = null } = props;
  render(
    <ConfirmBalanceForfeitOnPayoutMethodChangeModal
      balance={balance}
      losesBankRail={losesBankRail}
      bankAccountNumberVisual={bankAccountNumberVisual}
      open
      onClose={onClose}
      onConfirm={onConfirm}
    />,
  );
};

const removalWarning = () => screen.queryByText(/will be removed from your payout settings/u);

beforeEach(() => {
  onClose.mockReset();
  onConfirm.mockReset();
  Object.assign(globalThis, { Routes: { help_center_root_path: () => "/help" } });
});
afterEach(cleanup);

describe("rail-loss warning", () => {
  it("names the saved account with the masked value the server already sent", () => {
    renderModal({ losesBankRail: true, bankAccountNumberVisual: "******6789" });

    expect(removalWarning()).toBeTruthy();
    expect(screen.getByText("******6789")).toBeTruthy();
    expect(screen.getByText(/you will not be able to switch back yourself/u)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Contact support" }).getAttribute("href")).toBe("/help");
  });

  it("identifies the account without offering a raw or editable account field", () => {
    renderModal({ losesBankRail: true, bankAccountNumberVisual: "******6789" });

    // The confirmation phrase is the only thing the seller may type here.
    const inputs = screen.getAllByRole("textbox");
    expect(inputs).toHaveLength(1);
    expect(inputs[0]?.getAttribute("id")).toBe("confirmation-input");
    expect(screen.queryByLabelText(/account number/iu)).toBeNull();
    expect(screen.queryByLabelText(/account holder/iu)).toBeNull();
    expect(document.body.textContent).not.toMatch(/\b\d{5,}\b/u);
  });

  it("falls back to a generic mention when no saved account reaches the modal", () => {
    renderModal({ losesBankRail: true });

    expect(removalWarning()).toBeTruthy();
    expect(document.body.textContent).toContain("your bank account will be removed from your payout settings");
    expect(document.body.textContent).not.toMatch(/null|undefined/u);
  });

  it("promises support help rather than a restoration the seller cannot get back themselves", () => {
    renderModal({ losesBankRail: true, bankAccountNumberVisual: "******6789" });

    const body = document.body.textContent ?? "";
    expect(body).toContain("Contact support if you need help");
    expect(body).not.toMatch(/restore|permanently deleted|switch back at any time/iu);
  });
});

describe("balance-only confirmation", () => {
  it("keeps the forfeiture copy and adds no account identity", () => {
    renderModal({ balance: "$123.45", bankAccountNumberVisual: "******6789" });

    expect(screen.getByText(/forfeit your existing balance of/u)).toBeTruthy();
    expect(screen.getByText("$123.45")).toBeTruthy();
    expect(removalWarning()).toBeNull();
    expect(screen.queryByText("******6789")).toBeNull();
  });

  it("requires the typed acknowledgment before confirming", () => {
    renderModal({ balance: "$123.45" });

    const confirm = screen.getByRole("button", { name: "Confirm" });
    expect(confirm.hasAttribute("disabled")).toBe(true);
    fireEvent.change(screen.getByLabelText('Type "I understand" to confirm'), { target: { value: "I understand" } });
    fireEvent.click(confirm);
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });
});

describe("plain method change", () => {
  it("confirms without an acknowledgment when nothing is lost", () => {
    renderModal();

    expect(screen.queryByLabelText('Type "I understand" to confirm')).toBeNull();
    expect(removalWarning()).toBeNull();
    const confirm = screen.getByRole("button", { name: "Confirm" });
    expect(confirm.hasAttribute("disabled")).toBe(false);
    fireEvent.click(confirm);
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it("cancels without confirming", () => {
    renderModal({ losesBankRail: true, bankAccountNumberVisual: "******6789" });

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();
  });
});
