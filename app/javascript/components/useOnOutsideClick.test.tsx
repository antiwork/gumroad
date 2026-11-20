// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

afterEach(cleanup);

const Menu = ({ onOutside }: { onOutside: () => void }) => {
  const menu = React.useRef<HTMLDivElement>(null);
  useOnOutsideClick([menu], onOutside);
  return (
    <>
      <div ref={menu}>
        <button>
          <svg role="img" aria-label="Inside" />
        </button>
      </div>
      <button>
        <svg role="img" aria-label="Outside" />
      </button>
    </>
  );
};

it("counts an SVG click as outside only when it is outside the menu", () => {
  const onOutside = vi.fn();
  render(<Menu onOutside={onOutside} />);
  fireEvent.mouseUp(screen.getByRole("img", { name: "Inside" }));
  expect(onOutside).not.toHaveBeenCalled();
  fireEvent.mouseUp(screen.getByRole("img", { name: "Outside" }));
  expect(onOutside).toHaveBeenCalledOnce();
});
