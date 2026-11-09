// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { PublishScheduleCard } from "$app/components/PublishScheduleCard";

const schedule = {
  status: "scheduled",
  label: "December 2, 2026 at 9:30 AM PST",
  failure_message: null,
};

describe("PublishScheduleCard", () => {
  afterEach(cleanup);

  it("renders nothing when scheduling is unavailable", () => {
    const { container } = render(
      <PublishScheduleCard permalink="abc" schedule={null} canCreate={false} isPublished={false} />,
    );
    expect(container.innerHTML).toBe("");
  });

  it("offers scheduling when enabled", () => {
    render(<PublishScheduleCard permalink="abc" schedule={null} canCreate isPublished={false} />);
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Schedule publish" }).disabled).toBe(true);
  });

  it("shows a pending schedule in local time with a cancel button, even when creation is off", () => {
    render(<PublishScheduleCard permalink="abc" schedule={schedule} canCreate={false} isPublished={false} />);
    expect(screen.getByText("Scheduled to publish on December 2, 2026 at 9:30 AM PST.")).toBeTruthy();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel schedule" }).disabled).toBe(false);
  });

  it("renders nothing once the product is published", () => {
    const { container } = render(<PublishScheduleCard permalink="abc" schedule={null} canCreate isPublished />);
    expect(container.innerHTML).toBe("");
  });

  it("shows a saved failure banner", () => {
    render(
      <PublishScheduleCard
        permalink="abc"
        schedule={{ ...schedule, status: "failed", failure_message: "Gate failed" }}
        canCreate={false}
        isPublished={false}
      />,
    );
    expect(screen.getByText(/Scheduled publish failed: Gate failed/u)).toBeTruthy();
  });
});
