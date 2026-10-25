// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { leaveServer } from "$app/data/discord_integration";

import { DiscordButton } from "$app/components/DiscordButton";
import { showAlert } from "$app/components/server-components/Alert";

vi.mock("@boxicons/react", () => ({ Discord: () => null }));
vi.mock("$app/data/discord_integration", () => ({ joinServer: vi.fn(), leaveServer: vi.fn() }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it("restores the leave control after a network failure without changing membership", async () => {
  vi.mocked(leaveServer).mockRejectedValueOnce(new Error("Offline"));
  render(<DiscordButton purchaseId="purchase-1" connected />);
  fireEvent.click(screen.getByRole("button", { name: "Leave Discord" }));
  await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Could not leave the Discord server.", "error"));
  expect(screen.queryByRole("button", { name: "Leave Discord" })).not.toBeNull();
  expect(screen.queryByRole("button", { name: "Join Discord" })).toBeNull();

  vi.mocked(leaveServer).mockResolvedValueOnce({ ok: true, serverName: "Creators" });
  fireEvent.click(screen.getByRole("button", { name: "Leave Discord" }));
  await waitFor(() => expect(screen.queryByRole("button", { name: "Join Discord" })).not.toBeNull());
  expect(leaveServer).toHaveBeenCalledTimes(2);
});

it("leaves the membership unchanged after an HTTP refusal", async () => {
  vi.mocked(leaveServer).mockResolvedValueOnce({ ok: false });
  render(<DiscordButton purchaseId="purchase-1" connected />);
  fireEvent.click(screen.getByRole("button", { name: "Leave Discord" }));
  await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Could not leave the Discord server.", "error"));
  expect(screen.queryByRole("button", { name: "Leave Discord" })).not.toBeNull();
});
