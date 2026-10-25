// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useSortingTableDriver } from "$app/components/useSortingTableDriver";

afterEach(cleanup);
const renderHead = (props: React.ComponentProps<typeof TableHead>) =>
  render(
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead {...props}>Source</TableHead>
        </TableRow>
      </TableHeader>
    </Table>,
  );

describe("sortable table headers", () => {
  it("exposes a native non-submitting sort button", () => {
    renderHead({ sortDirection: "none", onClick: vi.fn() });
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Source" }).type).toBe("button");
  });

  it("retains sort state on the table header", () => {
    renderHead({ sortDirection: "ascending", onClick: vi.fn() });
    expect(screen.getByRole("columnheader").getAttribute("aria-sort")).toBe("ascending");
    expect(screen.getByRole("button", { name: "Source" })).toBeTruthy();
  });

  it("calls the existing click handler only once", () => {
    const onClick = vi.fn();
    renderHead({ sortDirection: "none", onClick });
    fireEvent.click(screen.getByRole("button", { name: "Source" }));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("supports the onSort API without changing header clicks", () => {
    const onSort = vi.fn();
    renderHead({ sortDirection: "none", onSort });
    fireEvent.click(screen.getByRole("button", { name: "Source" }));
    fireEvent.click(screen.getByRole("columnheader"));
    expect(onSort).toHaveBeenCalledTimes(2);
  });

  it("does not make static headers interactive", () => {
    renderHead({});
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.getByRole("columnheader").textContent).toBe("Source");
  });

  it("does not offer a sort control without a callback", () => {
    renderHead({ sortDirection: "ascending" });
    expect(screen.queryByRole("button")).toBeNull();
  });

  it("preserves driver direction toggling and mobile cell labels", () => {
    const changeSort = vi.fn();
    function DriverTable() {
      const thProps = useSortingTableDriver({ key: "source", direction: "asc" }, changeSort);
      return (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead {...thProps("source")}>Source</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            <TableRow>
              <TableCell>Newsletter</TableCell>
            </TableRow>
          </TableBody>
        </Table>
      );
    }
    render(<DriverTable />);
    fireEvent.click(screen.getByRole("button", { name: "Source" }));
    expect(changeSort).toHaveBeenCalledWith({ key: "source", direction: "desc" });
    expect(screen.getByRole("cell").textContent).toContain("Source");
    expect(screen.getByRole("cell").querySelector("button")).toBeNull();
  });
});
