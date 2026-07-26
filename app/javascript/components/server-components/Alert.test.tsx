// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import ToastAlert, { showAlertAfterReload } from "$app/components/server-components/Alert";

afterEach(() => {
  cleanup();
  window.sessionStorage.clear();
});

const isShown = () => !screen.getByTestId("toast-alert").className.includes("invisible");

describe("ToastAlert", () => {
  it("shows a toast that was queued for after a reload", () => {
    // What a caller does right before window.location.reload(): the current
    // document is about to be thrown away, so the message has to survive it.
    showAlertAfterReload("Your content couldn't be read and was left as it was.", "warning");

    render(<ToastAlert initial={null} />);

    expect(screen.getByText("Your content couldn't be read and was left as it was.")).toBeTruthy();
    expect(isShown()).toBe(true);
  });

  it("shows the queued toast only once", () => {
    showAlertAfterReload("Saved, but part of it couldn't be read.", "warning");

    const first = render(<ToastAlert initial={null} />);
    expect(screen.getByText("Saved, but part of it couldn't be read.")).toBeTruthy();
    first.unmount();

    render(<ToastAlert initial={null} />);
    expect(screen.queryByText("Saved, but part of it couldn't be read.")).toBeNull();
    expect(isShown()).toBe(false);
  });

  it("prefers a queued toast over a server-rendered one", () => {
    showAlertAfterReload("Part of this product's content couldn't be read.", "warning");

    render(<ToastAlert initial={{ message: "Welcome back!", status: "success" }} />);

    expect(screen.getByText("Part of this product's content couldn't be read.")).toBeTruthy();
    expect(screen.queryByText("Welcome back!")).toBeNull();
  });

  it("shows nothing when there is neither a queued nor an initial toast", () => {
    render(<ToastAlert initial={null} />);

    expect(isShown()).toBe(false);
  });

  it("ignores a stored value that isn't a toast", () => {
    window.sessionStorage.setItem("pendingAlert", "not json");

    render(<ToastAlert initial={{ message: "Welcome back!", status: "success" }} />);

    expect(screen.getByText("Welcome back!")).toBeTruthy();
  });

  it("ignores a stored value that parses but isn't shaped like a toast", () => {
    // Unlike the "not json" case above, this survives JSON.parse, so the shape
    // check is the only thing that can reject it. Anything can write to this
    // storage key — another tab on an older build, or a half-written value — and
    // a message that isn't a string would reach the DOM as whatever it happens
    // to be.
    window.sessionStorage.setItem("pendingAlert", JSON.stringify({ message: 123, status: "warning" }));

    render(<ToastAlert initial={{ message: "Welcome back!", status: "success" }} />);

    expect(screen.getByText("Welcome back!")).toBeTruthy();
  });
});
