// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import ToastAlert from "$app/components/server-components/Alert";
import { WishlistEditor } from "$app/components/Wishlist/WishlistEditor";

const fetchRequest = vi.hoisted(() => vi.fn());

beforeEach(() => {
  fetchRequest.mockReset();
  vi.stubGlobal("Routes", { wishlist_path: (id: string) => `/wishlists/${id}` });
  vi.stubGlobal("fetch", fetchRequest);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const Editor = ({ description = null }: { description?: string | null }) => {
  const [name, setName] = React.useState("My Wishlist");
  const [savedDescription, setDescription] = React.useState(description);
  return (
    <>
      <h1>{name}</h1>
      <p data-testid="saved-description">{savedDescription}</p>
      <WishlistEditor
        id="wishlist-1"
        name={name}
        setName={setName}
        description={savedDescription}
        setDescription={setDescription}
        isDiscoverable={false}
        onClose={() => {}}
      />
      <ToastAlert initial={null} />
    </>
  );
};

const errorResponse = (error: string) =>
  new Response(JSON.stringify({ error }), { status: 422, headers: { "Content-Type": "application/json" } });

describe("WishlistEditor validation", () => {
  it("keeps the saved name after rejection and saves a corrected edit", async () => {
    fetchRequest.mockResolvedValueOnce(errorResponse("Name can't be blank"));
    fetchRequest.mockResolvedValueOnce(new Response(null, { status: 204 }));
    render(<Editor />);
    const input = screen.getByLabelText<HTMLInputElement>("Name");

    fireEvent.change(input, { target: { value: "" } });
    fireEvent.blur(input);

    await waitFor(() => expect(screen.getByText("Name can't be blank")).toBeTruthy());
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("My Wishlist");
    expect(screen.queryByText("Changes saved!")).toBeNull();
    expect(JSON.parse(fetchRequest.mock.calls[0]?.[1].body)).toEqual({ wishlist: { name: "", description: null } });

    fireEvent.change(input, { target: { value: "Corrected wishlist" } });
    fireEvent.blur(input);

    await waitFor(() => expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("Corrected wishlist"));
    expect(screen.getByText("Changes saved!")).toBeTruthy();
    expect(fetchRequest).toHaveBeenCalledTimes(2);
  });

  it("keeps the saved description after rejection and allows clearing it", async () => {
    fetchRequest.mockResolvedValueOnce(errorResponse("Description is too long (maximum is 3000 characters)"));
    fetchRequest.mockResolvedValueOnce(new Response(null, { status: 204 }));
    render(<Editor description="Saved description" />);
    const input = screen.getByLabelText<HTMLInputElement>("Description");

    fireEvent.change(input, { target: { value: "x".repeat(3001) } });
    fireEvent.blur(input);

    await waitFor(() => expect(screen.getByText("Description is too long (maximum is 3000 characters)")).toBeTruthy());
    expect(screen.getByTestId("saved-description").textContent).toBe("Saved description");
    expect(screen.queryByText("Changes saved!")).toBeNull();

    fireEvent.change(input, { target: { value: "" } });
    fireEvent.blur(input);

    await waitFor(() => expect(screen.getByTestId("saved-description").textContent).toBe(""));
    expect(JSON.parse(fetchRequest.mock.calls[1]?.[1].body)).toEqual({
      wishlist: { name: "My Wishlist", description: null },
    });
  });

  it("skips unchanged fields", () => {
    render(<Editor />);

    fireEvent.blur(screen.getByLabelText("Name"));
    fireEvent.blur(screen.getByLabelText("Description"));

    expect(fetchRequest).not.toHaveBeenCalled();
  });
});
