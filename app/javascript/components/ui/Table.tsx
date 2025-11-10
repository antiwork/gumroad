import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

const TableContext = React.createContext<{ busy?: boolean | undefined }>({});
const useTable = () => assertDefined(React.useContext(TableContext), "useTable must be used within a Table");

export const Table = ({
  className,
  busy,
  children,
  ...props
}: React.HTMLAttributes<HTMLTableElement> & { busy?: boolean }) => {
  const contextValue = React.useMemo(() => ({ busy }), [busy]);
  return (
    <TableContext.Provider value={contextValue}>
      <table
        aria-busy={busy}
        className={classNames(
          "custom-table grid w-full border-spacing-0 gap-4 lg:table lg:rounded-sm lg:border lg:border-border",
          className,
        )}
        {...props}
      >
        {children}
      </table>
    </TableContext.Provider>
  );
};

export const TableCaption = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableCaptionElement>) => (
  <caption className={classNames("block text-left text-base text-xl lg:mb-4 lg:table-caption", className)} {...props}>
    {children}
  </caption>
);

export const TableHeader = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => (
  <thead className={classNames("hidden lg:table-header-group", className)} {...props}>
    {children}
  </thead>
);

export const TableBody = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => {
  const { busy } = useTable();
  return (
    <tbody
      className={classNames(
        "contents lg:table-row-group lg:rounded-sm lg:bg-background",
        busy && "pointer-events-none opacity-50",
        className,
      )}
      {...props}
    >
      {children}
    </tbody>
  );
};

export const TableFooter = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => {
  const { busy } = useTable();
  return (
    <tfoot
      className={classNames(
        "contents font-bold lg:table-footer-group",
        busy && "pointer-events-none opacity-50",
        className,
      )}
      {...props}
    >
      {children}
    </tfoot>
  );
};

export const TableRow = ({
  className,
  selected,
  children,
  ...props
}: React.HTMLAttributes<HTMLTableRowElement> & { selected?: boolean; footer?: boolean }) => (
  <tr
    aria-selected={selected}
    className={classNames(
      "block rounded-sm border border-border bg-background lg:table-row lg:border-0 lg:bg-transparent",
      selected && "cursor-pointer hover:bg-active-bg",
      className,
    )}
    {...props}
  >
    {children}
  </tr>
);

export const TableHead = ({
  className,
  sortable,
  sortDirection,
  onSort,
  children,
  ...props
}: React.ThHTMLAttributes<HTMLTableCellElement> & {
  sortable?: boolean;
  sortDirection?: "ascending" | "descending" | "none";
  onSort?: () => void;
}) => (
  <th
    aria-sort={sortable ? sortDirection : undefined}
    onClick={sortable ? onSort : undefined}
    className={classNames(
      "px-4 py-3 text-left align-middle lg:table-cell lg:whitespace-nowrap",
      sortable && "cursor-pointer",
      className,
    )}
    {...props}
  >
    <span className="inline-flex items-center gap-1">
      {children}
      {sortable && sortDirection && sortDirection !== "none" ? (
        <span className="inline-block">{sortDirection === "ascending" ? "↑" : "↓"}</span>
      ) : null}
    </span>
  </th>
);

export const TableCell = ({
  className,
  busy,
  actions,
  label,
  isIcon,
  children,
  ...props
}: React.TdHTMLAttributes<HTMLTableCellElement> & {
  busy?: boolean;
  actions?: boolean;
  label?: string;
  isIcon?: boolean;
}) => (
  <td
    aria-busy={busy}
    className={classNames(
      "block p-4 text-left align-middle lg:table-cell lg:border-t lg:border-border lg:before:content-none [&:not(:first-child)]:border-t [&:not(:first-child)]:border-border",
      actions && "grid auto-cols-max grid-flow-col gap-3 lg:justify-end",
      isIcon && "text-center text-xl lg:w-20 lg:min-w-20 lg:border-r lg:border-border",
      className,
    )}
    {...props}
  >
    {label ? <div className="mb-2 font-bold lg:hidden">{label}</div> : null}
    {children}
    {busy ? <div className="h-[1lh] w-full animate-pulse rounded-full bg-border content-['']" /> : null}
  </td>
);
