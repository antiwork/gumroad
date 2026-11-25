// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { fetchCommunities, fetchSpaceGroups } from "$app/data/circle_integration";

import {
  CircleIntegration,
  CircleIntegrationEditor,
} from "$app/components/ProductEdit/ProductTab/CircleIntegrationEditor";

vi.mock("$app/data/circle_integration", () => ({
  fetchCommunities: vi.fn(),
  fetchSpaceGroups: vi.fn(),
}));
vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({ product: { native_type: "membership", variants: [] }, updateProduct: vi.fn() }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

const integration: CircleIntegration = {
  name: "circle",
  api_key: "key",
  keep_inactive_members: false,
  integration_details: { community_id: "1", space_group_id: "2" },
};

const switchLabel = "Invite your customers to a Circle community";

const renderEditor = async () => {
  vi.mocked(fetchCommunities).mockResolvedValue({ communities: [{ id: 1, name: "Community" }] });
  vi.mocked(fetchSpaceGroups).mockResolvedValue({
    spaceGroups: [
      { id: 2, name: "Group two" },
      { id: 3, name: "Group three" },
    ],
  });
  const onChange = vi.fn();
  render(<CircleIntegrationEditor integration={integration} onChange={onChange} />);
  await act(async () => {});
  onChange.mockClear();
  return onChange;
};

it("does not restore the integration when the space group changes after the seller turns the switch off", async () => {
  const onChange = await renderEditor();

  fireEvent.click(screen.getByRole("switch", { name: switchLabel }));
  expect(onChange).toHaveBeenCalledExactlyOnceWith(null);

  onChange.mockClear();
  fireEvent.change(screen.getByLabelText("Select a space group"), { target: { value: "3" } });
  expect(onChange).not.toHaveBeenCalled();
});

it("restores the integration when the seller turns the switch back on", async () => {
  const onChange = await renderEditor();
  const toggle = screen.getByRole("switch", { name: switchLabel });

  fireEvent.click(toggle);
  onChange.mockClear();
  fireEvent.click(toggle);

  expect(onChange).toHaveBeenCalledExactlyOnceWith(integration);
});

it("still writes the integration when the space group changes while the switch is on", async () => {
  const onChange = await renderEditor();

  fireEvent.change(screen.getByLabelText("Select a space group"), { target: { value: "3" } });

  expect(onChange).toHaveBeenCalledExactlyOnceWith({
    ...integration,
    integration_details: { community_id: "1", space_group_id: "3" },
  });
});

it.each([true, false])("preserves saved membership retention %s on load and group selection", async (keepInactive) => {
  vi.mocked(fetchCommunities).mockResolvedValue({ communities: [{ id: 1, name: "Community" }] });
  vi.mocked(fetchSpaceGroups).mockResolvedValue({
    spaceGroups: [
      { id: 2, name: "Original" },
      { id: 3, name: "New" },
    ],
  });
  const saved = { ...integration, keep_inactive_members: keepInactive };
  const onChange = vi.fn();
  render(<CircleIntegrationEditor integration={saved} onChange={onChange} />);
  const groups = await screen.findByRole("combobox", { name: "Select a space group" });
  expect(onChange).not.toHaveBeenCalled();
  expect(screen.getByRole("checkbox", { name: "Do not remove Circle access when membership ends" })).toHaveProperty(
    "checked",
    keepInactive,
  );
  fireEvent.change(groups, { target: { value: "3" } });
  expect(onChange).toHaveBeenCalledExactlyOnceWith({
    ...saved,
    integration_details: { community_id: "1", space_group_id: "3" },
  });
});

it("defaults a newly selected Circle integration to removing inactive members", async () => {
  vi.mocked(fetchCommunities).mockResolvedValue({ communities: [{ id: 1, name: "Community" }] });
  vi.mocked(fetchSpaceGroups).mockResolvedValue({ spaceGroups: [{ id: 3, name: "New" }] });
  const onChange = vi.fn();
  render(<CircleIntegrationEditor integration={null} onChange={onChange} />);
  fireEvent.click(screen.getByRole("switch", { name: switchLabel }));
  fireEvent.change(screen.getByLabelText("API Token"), { target: { value: "new-key" } });
  fireEvent.click(screen.getByRole("button", { name: "Load communities" }));
  fireEvent.change(await screen.findByRole("combobox", { name: "Select a community" }), { target: { value: "1" } });
  fireEvent.change(await screen.findByRole("combobox", { name: "Select a space group" }), { target: { value: "3" } });
  expect(onChange).toHaveBeenCalledExactlyOnceWith({
    name: "circle",
    api_key: "new-key",
    keep_inactive_members: false,
    integration_details: { community_id: "1", space_group_id: "3" },
  });
});
