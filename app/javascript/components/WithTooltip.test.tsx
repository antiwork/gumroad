// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Button } from "$app/components/Button";
import { Pill } from "$app/components/ui/Pill";
import { WithTooltip } from "$app/components/WithTooltip";

afterEach(cleanup);

const descriptions = (element: Element) => element.getAttribute("aria-describedby")?.split(/\s+/u) ?? [];

describe("WithTooltip control descriptions", () => {
  it("describes a native button with the tooltip", () => {
    render(
      <WithTooltip tip="More detail">
        <Button>Action</Button>
      </WithTooltip>,
    );
    expect(descriptions(screen.getByRole("button"))).toEqual([screen.getByRole("tooltip").id]);
  });

  it("reaches a nested control without replacing its ref or click handler", () => {
    const ref = React.createRef<HTMLButtonElement>();
    const onClick = vi.fn();
    render(
      <WithTooltip tip="More detail">
        <span>
          <Pill asChild>
            <Button ref={ref} onClick={onClick}>
              Action
            </Button>
          </Pill>
        </span>
      </WithTooltip>,
    );
    const button = screen.getByRole("button");
    expect(descriptions(button)).toEqual([screen.getByRole("tooltip").id]);
    expect(ref.current).toBe(button);
    fireEvent.click(button);
    expect(onClick).toHaveBeenCalledOnce();
  });

  it("describes each focusable descendant including links and custom controls", () => {
    render(
      <WithTooltip tip="More detail">
        <a href="https://example.com">Link</a>
        <input aria-label="Name" />
        <span role="button" tabIndex={0}>
          Custom
        </span>
      </WithTooltip>,
    );
    for (const control of [screen.getByRole("link"), screen.getByRole("textbox"), screen.getByRole("button")]) {
      expect(descriptions(control)).toEqual([screen.getByRole("tooltip").id]);
    }
  });

  it("keeps existing description IDs and honors an explicit tooltip ID", () => {
    render(
      <WithTooltip tip="More detail" tooltipProps={{ id: "action-tip" }}>
        <Button aria-describedby="first second">Action</Button>
      </WithTooltip>,
    );
    expect(descriptions(screen.getByRole("button"))).toEqual(["first", "second", "action-tip"]);
    expect(screen.getByRole("tooltip").id).toBe("action-tip");
  });

  it("removes only its own description when the tip disappears", () => {
    const { rerender } = render(
      <WithTooltip tip="More detail">
        <Button aria-describedby="existing">Action</Button>
      </WithTooltip>,
    );
    const button = screen.getByRole("button");
    expect(descriptions(button)).toHaveLength(2);
    rerender(
      <WithTooltip tip={null}>
        <Button aria-describedby="existing">Action</Button>
      </WithTooltip>,
    );
    expect(descriptions(button)).toEqual(["existing"]);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("associates controls added by a child's own state update", async () => {
    const Child = () => {
      const [shown, setShown] = React.useState(false);
      return (
        <>
          <Button onClick={() => setShown(true)}>Show</Button>
          {shown ? <Button>New action</Button> : null}
        </>
      );
    };
    render(
      <WithTooltip tip="More detail">
        <Child />
      </WithTooltip>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Show" }));
    await waitFor(() =>
      expect(descriptions(screen.getByRole("button", { name: "New action" }))).toEqual([
        screen.getByRole("tooltip").id,
      ]),
    );
  });

  it("retains updated caller descriptions and cleans up detached controls", async () => {
    const { unmount } = render(
      <WithTooltip tip="More detail">
        <Button>Action</Button>
      </WithTooltip>,
    );
    const button = screen.getByRole("button");
    const id = screen.getByRole("tooltip").id;
    button.setAttribute("aria-describedby", "new-description");
    await waitFor(() => expect(descriptions(button)).toEqual(["new-description", id]));
    unmount();
    expect(descriptions(button)).toEqual(["new-description"]);
  });

  it("removes stale associations when a child replaces a control", async () => {
    const Child = () => {
      const [replaced, setReplaced] = React.useState(false);
      return replaced ? (
        <a href="https://example.com">Replacement</a>
      ) : (
        <Button onClick={() => setReplaced(true)}>Replace</Button>
      );
    };
    render(
      <WithTooltip tip="More detail">
        <Child />
      </WithTooltip>,
    );
    const oldButton = screen.getByRole("button");
    fireEvent.click(oldButton);
    await waitFor(() => expect(descriptions(screen.getByRole("link"))).toEqual([screen.getByRole("tooltip").id]));
    expect(descriptions(oldButton)).toEqual([]);
  });

  it("keeps both tooltip descriptions when wrappers are nested", () => {
    render(
      <WithTooltip tip="Outer detail">
        <WithTooltip tip="Inner detail">
          <Button>Action</Button>
        </WithTooltip>
      </WithTooltip>,
    );
    expect(descriptions(screen.getByRole("button")).sort()).toEqual(
      screen
        .getAllByRole("tooltip")
        .map((tip) => tip.id)
        .sort(),
    );
  });

  it("releases a control that is no longer a tooltip target", async () => {
    render(
      <WithTooltip tip="More detail">
        <span tabIndex={0}>Custom</span>
      </WithTooltip>,
    );
    const control = screen.getByText("Custom");
    expect(descriptions(control)).toHaveLength(1);
    control.removeAttribute("tabindex");
    await waitFor(() => expect(descriptions(control)).toEqual([]));
  });

  it("does not duplicate description IDs under StrictMode", () => {
    render(
      <React.StrictMode>
        <WithTooltip tip="More detail">
          <Button>Action</Button>
        </WithTooltip>
      </React.StrictMode>,
    );
    expect(descriptions(screen.getByRole("button"))).toEqual([screen.getByRole("tooltip").id]);
  });

  it("does not remove a description supplied by the caller", () => {
    const { rerender } = render(
      <WithTooltip tip="More detail" tooltipProps={{ id: "shared-tip" }}>
        <Button aria-describedby="shared-tip">Action</Button>
      </WithTooltip>,
    );
    rerender(
      <WithTooltip tip={null} tooltipProps={{ id: "shared-tip" }}>
        <Button aria-describedby="shared-tip">Action</Button>
      </WithTooltip>,
    );
    expect(descriptions(screen.getByRole("button"))).toEqual(["shared-tip"]);
  });

  it("keeps the wrapper description for noninteractive content", () => {
    render(
      <WithTooltip tip="More detail">
        <span>Label</span>
      </WithTooltip>,
    );
    expect(screen.getByText("Label").parentElement?.getAttribute("aria-describedby")).toBe(
      screen.getByRole("tooltip").id,
    );
  });

  it("leaves controls unchanged when no tip exists", () => {
    render(
      <WithTooltip tip={null}>
        <Button aria-describedby="existing">Action</Button>
      </WithTooltip>,
    );
    expect(descriptions(screen.getByRole("button"))).toEqual(["existing"]);
  });
});
