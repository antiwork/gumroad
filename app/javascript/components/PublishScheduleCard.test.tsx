// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { type CurrentSeller, CurrentSellerProvider } from "$app/components/CurrentSeller";
import { PublishScheduleCard } from "$app/components/PublishScheduleCard";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const schedule = {
  status: "scheduled",
  label: "December 2, 2026 at 9:30 AM PST",
  failure_message: null,
};

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: { link_publish_schedule_path: (permalink: string) => `/links/${permalink}/publish_schedule` },
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const respondWith = (body: unknown) =>
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(new Response(JSON.stringify(body)))),
  );

const seller: CurrentSeller = {
  id: "1",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "America/Los_Angeles", offset: -28800 },
  has_published_products: false,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: false,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const renderCard = (ui: React.ReactElement, currentSeller: CurrentSeller | null = null) =>
  render(ui, {
    wrapper: ({ children }) => <CurrentSellerProvider value={currentSeller}>{children}</CurrentSellerProvider>,
  });

describe("PublishScheduleCard", () => {
  it("names the seller's time zone for the chosen time", () => {
    renderCard(
      <PublishScheduleCard permalink="abc" schedule={null} onChange={vi.fn()} canCreate isPublished={false} />,
      seller,
    );

    fireEvent.change(screen.getByLabelText("Publish at"), { target: { value: "2026-12-02T09:30" } });
    expect(screen.getByText("PST")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Publish at"), { target: { value: "2027-07-02T09:30" } });
    expect(screen.getByText("PDT")).toBeTruthy();
  });

  it("announces a pending schedule as a status rather than an alert", () => {
    renderCard(
      <PublishScheduleCard permalink="abc" schedule={schedule} onChange={vi.fn()} canCreate isPublished={false} />,
    );
    expect(screen.getByRole("status").textContent).toContain("Scheduled to publish on");
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("renders nothing when scheduling is unavailable", () => {
    const { container } = renderCard(
      <PublishScheduleCard permalink="abc" schedule={null} onChange={vi.fn()} canCreate={false} isPublished={false} />,
    );
    expect(container.innerHTML).toBe("");
  });

  it("offers scheduling when enabled", () => {
    renderCard(
      <PublishScheduleCard permalink="abc" schedule={null} onChange={vi.fn()} canCreate isPublished={false} />,
    );
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Schedule publish" }).disabled).toBe(true);
  });

  it("shows a pending schedule in local time with a cancel button, even when creation is off", () => {
    renderCard(
      <PublishScheduleCard
        permalink="abc"
        schedule={schedule}
        onChange={vi.fn()}
        canCreate={false}
        isPublished={false}
      />,
    );
    expect(screen.getByText("Scheduled to publish on December 2, 2026 at 9:30 AM PST.")).toBeTruthy();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel schedule" }).disabled).toBe(false);
  });

  it("renders nothing once the product is published", () => {
    const { container } = renderCard(
      <PublishScheduleCard permalink="abc" schedule={null} onChange={vi.fn()} canCreate isPublished />,
    );
    expect(container.innerHTML).toBe("");
  });

  it("shows a saved failure banner", () => {
    renderCard(
      <PublishScheduleCard
        permalink="abc"
        schedule={{ ...schedule, status: "failed", failure_message: "Gate failed" }}
        onChange={vi.fn()}
        canCreate={false}
        isPublished={false}
      />,
    );
    expect(screen.getByText(/Scheduled publish failed: Gate failed/u)).toBeTruthy();
  });

  it("shows the schedule the editor holds, not the one it first rendered with", () => {
    const { rerender } = renderCard(
      <PublishScheduleCard permalink="abc" schedule={schedule} onChange={vi.fn()} canCreate isPublished={false} />,
    );
    rerender(<PublishScheduleCard permalink="abc" schedule={null} onChange={vi.fn()} canCreate isPublished={false} />);

    expect(screen.queryByText(/Scheduled to publish/u)).toBeNull();
    expect(screen.getByRole("button", { name: "Schedule publish" })).toBeTruthy();
  });

  it("hands the saved schedule to the editor", async () => {
    respondWith({ success: true, publish_schedule: schedule });
    const onChange = vi.fn();
    renderCard(
      <PublishScheduleCard permalink="abc" schedule={null} onChange={onChange} canCreate isPublished={false} />,
    );

    fireEvent.change(screen.getByLabelText("Publish at"), { target: { value: "2026-12-02T09:30" } });
    fireEvent.click(screen.getByRole("button", { name: "Schedule publish" }));

    await waitFor(() => expect(onChange).toHaveBeenCalledWith(schedule));
  });

  it("clears the editor's schedule after cancelling", async () => {
    respondWith({ success: true });
    const onChange = vi.fn();
    renderCard(
      <PublishScheduleCard permalink="abc" schedule={schedule} onChange={onChange} canCreate isPublished={false} />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Cancel schedule" }));

    await waitFor(() => expect(onChange).toHaveBeenCalledWith(null));
  });
});
