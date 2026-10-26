// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { RatingSelector } from "$app/components/RatingSelector";

afterEach(cleanup);

describe("RatingSelector", () => {
  it("uses named native radios for keyboard selection", () => {
    render(<RatingSelector currentRating={null} onChangeCurrentRating={vi.fn()} />);
    const radios = screen.getAllByRole<HTMLInputElement>("radio");
    expect(radios).toHaveLength(5);
    expect(radios.map((radio) => radio.getAttribute("aria-label"))).toEqual([
      "1 star",
      "2 stars",
      "3 stars",
      "4 stars",
      "5 stars",
    ]);
    for (const radio of radios) {
      expect(radio.tagName).toBe("INPUT");
      expect(radio.type).toBe("radio");
      expect(radio.tabIndex).toBe(0);
      expect(radio.name).toBe(radios[0]?.name);
      expect(radio.name).not.toBe("");
    }
  });

  it("exposes the existing selected rating", () => {
    render(<RatingSelector currentRating={3} onChangeCurrentRating={vi.fn()} />);
    expect(screen.getByRole<HTMLInputElement>("radio", { name: "3 stars" }).checked).toBe(true);
    expect(screen.getByRole<HTMLInputElement>("radio", { name: "2 stars" }).checked).toBe(false);
  });

  it("selects a rating through its star label without submitting a surrounding form", () => {
    const onChange = vi.fn();
    const submit = vi.fn((event: React.FormEvent) => event.preventDefault());
    render(
      <form onSubmit={submit}>
        <RatingSelector currentRating={null} onChangeCurrentRating={onChange} />
      </form>,
    );
    const radio = screen.getByRole("radio", { name: "4 stars" });
    expect(radio.closest("label")).not.toBe(null);
    radio.closest("label")?.click();
    expect(onChange).toHaveBeenCalledExactlyOnceWith(4, expect.objectContaining({ type: "change" }));
    expect(submit).not.toHaveBeenCalled();
  });

  it("disables every rating and ignores star clicks when disabled", () => {
    const onChange = vi.fn();
    render(<RatingSelector currentRating={3} onChangeCurrentRating={onChange} disabled />);
    for (const radio of screen.getAllByRole<HTMLInputElement>("radio")) {
      expect(radio.disabled).toBe(true);
      radio.click();
      radio.closest("label")?.click();
    }
    expect(onChange).not.toHaveBeenCalled();
  });

  it("keeps separate selectors in separate native radio groups", () => {
    render(
      <>
        <RatingSelector currentRating={2} onChangeCurrentRating={vi.fn()} />
        <RatingSelector currentRating={4} onChangeCurrentRating={vi.fn()} />
      </>,
    );
    const radios = screen.getAllByRole<HTMLInputElement>("radio");
    expect(radios[0]?.name).not.toBe(radios[5]?.name);
    expect(radios[1]?.checked).toBe(true);
    expect(radios[8]?.checked).toBe(true);
  });

  it("retains the existing mouse selection callback", () => {
    const onChange = vi.fn();
    render(<RatingSelector currentRating={null} onChangeCurrentRating={onChange} />);
    fireEvent.click(screen.getByRole("radio", { name: "5 stars" }));
    expect(onChange).toHaveBeenCalledExactlyOnceWith(5, expect.objectContaining({ type: "change" }));
  });
});
