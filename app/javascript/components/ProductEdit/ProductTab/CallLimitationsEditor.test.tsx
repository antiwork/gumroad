// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Button } from "$app/components/Button";
import { CallLimitationsEditor } from "$app/components/ProductEdit/ProductTab/CallLimitationsEditor";
import type { CallLimitationInfo } from "$app/components/ProductEdit/state";

afterEach(cleanup);

const renderEditor = () => {
  const saved = vi.fn();
  const changed = vi.fn();
  const Harness = () => {
    const [limitations, setLimitations] = React.useState<CallLimitationInfo>({
      minimum_notice_in_minutes: 180,
      maximum_calls_per_day: 5,
    });
    return (
      <>
        <CallLimitationsEditor
          callLimitations={limitations}
          onChange={(next) => {
            changed(next);
            setLimitations(next);
          }}
        />
        <Button onClick={() => saved(limitations)}>Save</Button>
      </>
    );
  };
  render(<Harness />);
  return { saved, changed };
};

describe("CallLimitationsEditor", () => {
  it("saves a notice edit when Save is activated without an outside mouseup", () => {
    const { saved } = renderEditor();
    const input = screen.getByLabelText<HTMLInputElement>("Notice period");
    input.focus();
    fireEvent.change(input, { target: { value: "24" } });
    const save = screen.getByRole("button", { name: "Save" });
    save.focus();
    fireEvent.click(save);

    expect(saved).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 1440, maximum_calls_per_day: 5 });
  });

  it("commits a units-only edit without waiting for a mouse event", () => {
    const { changed, saved } = renderEditor();
    fireEvent.change(screen.getByLabelText("Units"), { target: { value: "days" } });
    expect(changed).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 4320, maximum_calls_per_day: 5 });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(saved).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 4320, maximum_calls_per_day: 5 });
  });

  it.each([
    { value: "", minutes: null },
    { value: "0", minutes: 0 },
  ])("saves a $value notice without restoring the old restriction", ({ value, minutes }) => {
    const { saved } = renderEditor();
    fireEvent.change(screen.getByLabelText("Notice period"), { target: { value } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(saved).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: minutes, maximum_calls_per_day: 5 });
  });

  it("keeps minutes selected while typing values that also represent whole hours", () => {
    const { changed } = renderEditor();
    const units = screen.getByLabelText<HTMLSelectElement>("Units");
    const input = screen.getByLabelText<HTMLInputElement>("Notice period");
    fireEvent.change(units, { target: { value: "minutes" } });
    fireEvent.change(input, { target: { value: "60" } });
    expect(units.value).toBe("minutes");
    expect(input.value).toBe("60");
    fireEvent.change(input, { target: { value: "120" } });
    expect(units.value).toBe("minutes");
    expect(input.value).toBe("120");
    expect(changed).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 120, maximum_calls_per_day: 5 });
  });

  it("normalizes the display after focus leaves the notice controls, keeping focus within them editable", () => {
    renderEditor();
    const units = screen.getByLabelText<HTMLSelectElement>("Units");
    const input = screen.getByLabelText<HTMLInputElement>("Notice period");
    fireEvent.change(units, { target: { value: "minutes" } });
    fireEvent.change(input, { target: { value: "1440" } });
    fireEvent.blur(input, { relatedTarget: units });
    expect(units.value).toBe("minutes");
    expect(input.value).toBe("1440");
    fireEvent.blur(units, { relatedTarget: screen.getByLabelText("Daily limit") });
    expect(units.value).toBe("days");
    expect(input.value).toBe("1");
  });

  it("retains the edited notice when the daily limit changes", () => {
    const { saved } = renderEditor();
    fireEvent.change(screen.getByLabelText("Notice period"), { target: { value: "24" } });
    fireEvent.change(screen.getByLabelText("Daily limit"), { target: { value: "7" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(saved).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 1440, maximum_calls_per_day: 7 });
  });

  it("continues saving notice edits through mouse activation", () => {
    const { saved } = renderEditor();
    fireEvent.change(screen.getByLabelText("Notice period"), { target: { value: "24" } });
    const save = screen.getByRole("button", { name: "Save" });
    fireEvent.mouseUp(save);
    fireEvent.click(save);
    expect(saved).toHaveBeenLastCalledWith({ minimum_notice_in_minutes: 1440, maximum_calls_per_day: 5 });
  });

  it("reconciles an externally changed notice instead of retaining obsolete local values", () => {
    const onChange = vi.fn();
    const { rerender } = render(
      <CallLimitationsEditor
        callLimitations={{ minimum_notice_in_minutes: 180, maximum_calls_per_day: 5 }}
        onChange={onChange}
      />,
    );
    fireEvent.change(screen.getByLabelText("Notice period"), { target: { value: "24" } });
    rerender(
      <CallLimitationsEditor
        callLimitations={{ minimum_notice_in_minutes: 4320, maximum_calls_per_day: 5 }}
        onChange={onChange}
      />,
    );
    expect(screen.getByLabelText<HTMLSelectElement>("Units").value).toBe("days");
    expect(screen.getByLabelText<HTMLInputElement>("Notice period").value).toBe("3");
  });

  it("keeps the selected unit when a parent applies the current edit after a delay", () => {
    const onChange = vi.fn();
    const { rerender } = render(
      <CallLimitationsEditor
        callLimitations={{ minimum_notice_in_minutes: 180, maximum_calls_per_day: 5 }}
        onChange={onChange}
      />,
    );
    fireEvent.change(screen.getByLabelText("Units"), { target: { value: "minutes" } });
    fireEvent.change(screen.getByLabelText("Notice period"), { target: { value: "60" } });
    expect(screen.getByLabelText<HTMLInputElement>("Notice period").value).toBe("60");
    rerender(
      <CallLimitationsEditor
        callLimitations={{ minimum_notice_in_minutes: 60, maximum_calls_per_day: 5 }}
        onChange={onChange}
      />,
    );
    expect(screen.getByLabelText<HTMLSelectElement>("Units").value).toBe("minutes");
    expect(screen.getByLabelText<HTMLInputElement>("Notice period").value).toBe("60");
  });
});
