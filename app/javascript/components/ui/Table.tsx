import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

const TableContext = React.createContext<{
  busy?: boolean | undefined;
  headerLabels?: (string | null)[];
  setHeaderLabels: (headerLabels: (string | null)[]) => void;
}>({ setHeaderLabels: () => {} });
const useTable = () => assertDefined(React.useContext(TableContext), "useTable must be used within a Table");

export const Table = React.forwardRef<
  HTMLTableElement,
  Omit<React.HTMLAttributes<HTMLTableElement>, "aria-busy"> & { busy?: boolean }
>(({ className, busy, children, ...props }, ref) => {
  const [headerLabels, setHeaderLabels] = React.useState<(string | null)[]>([]);
  const contextValue = React.useMemo(
    () => ({ busy, headerLabels, setHeaderLabels }),
    [busy, headerLabels, setHeaderLabels],
  );
  return (
    <TableContext.Provider value={contextValue}>
      <table
        ref={ref}
        aria-live={busy == null ? undefined : "polite"}
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
});
Table.displayName = "Table";

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
        "contents lg:table-row-group lg:rounded-sm",
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
}: Omit<React.HTMLAttributes<HTMLTableRowElement>, "aria-selected"> & { selected?: boolean; footer?: boolean }) => {
  const { headerLabels: headers, setHeaderLabels: setHeaders } = useTable();

  React.useEffect(() => {
    const isHeaderRow = React.Children.toArray(children).every(
      (child) => React.isValidElement(child) && child.type === TableHead,
    );
    if (!isHeaderRow) return;

    setHeaders(
      React.Children.toArray(children).map<string | null>((child) => {
        if (React.isValidElement(child) && child.type === TableHead) {
          // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
          const props = child.props as React.ComponentProps<typeof TableHead>;
          return typeof props.children === "string" ? props.children : null;
        }
        return null;
      }),
    );
  }, [children]);

  const childrenWithLabels = React.Children.map(children, (child, index) => {
    if (React.isValidElement(child) && child.type === TableCell) {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
      const cell = child as React.FunctionComponentElement<React.ComponentProps<typeof TableCell>>;
      const label = cell.props.label ?? headers?.[index] ?? null;
      return React.cloneElement(cell, label ? { label } : {});
    }
    return child;
  });

  return (
    <tr
      aria-selected={selected}
      className={classNames(
        "block rounded-sm border border-border bg-background lg:table-row lg:border-0 lg:bg-transparent",
        selected && "cursor-pointer hover:bg-active-bg",
        className,
      )}
      {...props}
    >
      {childrenWithLabels}
    </tr>
  );
};

export const TableHead = ({
  className,
  sortDirection,
  onSort,
  children,
  ...props
}: Omit<React.ThHTMLAttributes<HTMLTableCellElement>, "aria-sort"> & {
  sortDirection?: "ascending" | "descending" | "none";
  onSort?: () => void;
}) => (
  <th
    aria-sort={sortDirection}
    onClick={onSort}
    className={classNames(
      "px-4 py-3 text-left align-middle lg:table-cell lg:whitespace-nowrap",
      sortDirection && "cursor-pointer",
      className,
    )}
    {...props}
  >
    <span className="inline-flex items-center gap-1">
      {children}
      {sortDirection && sortDirection !== "none" ? (
        <span className="inline-block">{sortDirection === "ascending" ? "↑" : "↓"}</span>
      ) : null}
    </span>
  </th>
);

export const TableCell = ({
  className,
  actions,
  hideLabel,
  label,
  children,
  ...props
}: Omit<React.TdHTMLAttributes<HTMLTableCellElement>, "aria-busy"> & {
  actions?: boolean;
  hideLabel?: boolean;
  label?: string;
}) => (
  <td
    className={classNames(
      "block p-4 text-left align-middle not-first:border-t not-first:border-border lg:table-cell lg:border-t lg:border-border",
      "lg:[table_>_:last-child_>_tr:last-child_>_&:first-child]:rounded-bl-sm lg:[table_>_:last-child_>_tr:last-child_>_&:last-child]:rounded-br-sm lg:[tbody_>_tr_>_&]:bg-background",
      className,
    )}
    {...props}
  >
    {label ? <div className={classNames("mb-2 font-bold lg:hidden", hideLabel && "sr-only")}>{label}</div> : null}
    {actions ? <div className="flex flex-wrap gap-3 lg:justify-end">{children}</div> : children}
  </td>
);
