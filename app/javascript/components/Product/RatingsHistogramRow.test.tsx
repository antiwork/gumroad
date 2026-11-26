// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { RatingsHistogramRow } from "$app/components/Product/index";

afterEach(cleanup);

describe("RatingsHistogramRow", () => {
  // A 0% row is the whole track, so it is the row that disappears when the track is only the
  // divider hairline. Hold the track edge at the field-strength tier (3:1 on any store) and give
  // the empty track a shade off the surface, so the scale stays legible on a coloured store.
  it("edges the meter track at the field-strength tier", () => {
    const { container } = render(<RatingsHistogramRow rating={3} percentage={0} />);
    const meter = container.querySelector("meter");
    expect(meter).not.toBeNull();

    const classes = meter ? meter.className.split(" ") : [];
    expect(classes).toContain("border-control");
    expect(classes).not.toContain("border-border");
    expect(classes).toContain("bg-active-bg");
  });
});
