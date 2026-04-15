import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

const TableContext = React.createContext<{
  headerLabels?: React.ReactNode[];
  setHeaderLabels: (headerLabels: React.ReactNode[]) => void;
}>({ setHeaderLabels: () => {} });
const useTable = () => assertDefined(React.useContext(TableContext), "useTable must be used within a Table");

export const Table = React.forwardRef<HTMLTableElement, React.HTMLAttributes<HTMLTableElement>>(
  ({ className, children, ...props }, ref) => {
    const [headerLabels, setHeaderLabels] = React.useState<React.ReactNode[]>([]);
    const contextValue = React.useMemo(() => ({ headerLabels, setHeaderLabels }), [headerLabels, setHeaderLabels]);
    return (
      <TableContext.Provider value={contextValue}>
        <table
          ref={ref}
          className={classNames(
            "grid w-full border-spacing-0 gap-4 lg:table lg:rounded-sm lg:border lg:border-border",
            className,
          )}
          {...props}
        >
          {children}
        </table>
      </TableContext.Provider>
    );
  },
);
Table.displayName = "Table";

export const TableCaption = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableCaptionElement>) => (
  <caption className={classNames("block text-left text-base text-xl lg:mb-4 lg:table-caption", className)} {...props}>
    {children}
  </caption>
);

const RowGroupContext = React.createContext<"header" | "body" | "footer" | null>(null);

export const TableHeader = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => (
  <RowGroupContext.Provider value="header">
    <thead className={classNames("hidden lg:table-header-group", className)} {...props}>
      {children}
    </thead>
  </RowGroupContext.Provider>
);

export const TableBody = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => (
  <RowGroupContext.Provider value="body">
    <tbody className={classNames("contents lg:table-row-group lg:rounded-sm", className)} {...props}>
      {children}
    </tbody>
  </RowGroupContext.Provider>
);

export const TableFooter = ({ className, children, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) => (
  <RowGroupContext.Provider value="footer">
    <tfoot className={classNames("contents font-bold lg:table-footer-group", className)} {...props}>
      {children}
    </tfoot>
  </RowGroupContext.Provider>
);

const TableCellContext = React.createContext<{ label?: React.ReactNode } | null>(null);

export const TableRow = ({
  className,
  selected,
  children,
  ...props
}: Omit<React.HTMLAttributes<HTMLTableRowElement>, "aria-selected"> & { selected?: boolean; footer?: boolean }) => {
  const rowGroup = React.useContext(RowGroupContext);
  const { headerLabels: headers, setHeaderLabels: setHeaders } = useTable();

  React.useEffect(() => {
    if (rowGroup !== "header") return;

    setHeaders(
      React.Children.toArray(children).map<React.ReactNode>((child) => {
        if (React.isValidElement<React.ComponentProps<typeof TableHead>>(child) && child.type === TableHead) {
          return child.props.children;
        }
        return null;
      }),
    );
  }, [children, rowGroup]);

  const cellContexts = React.useMemo(
    () => React.Children.map(children, (_, index) => ({ label: headers?.[index] })) ?? [],
    [children, headers],
  );

  return (
    <tr
      aria-selected={selected}
      className={classNames(
        "block rounded-sm border border-border lg:table-row",
        rowGroup === "body" && "bg-background",
        selected != null && "cursor-pointer hover:bg-active-bg",
        selected && "bg-active-bg",
        className,
      )}
      {...props}
    >
      {React.Children.map(children, (child, index) => (
        <TableCellContext.Provider value={cellContexts[index] ?? null}>{child}</TableCellContext.Provider>
      ))}
    </tr>
  );
};

const cellRoundingClasses =
  "lg:[table_>_:last-child_>_tr:last-child_>_&:first-child]:rounded-bl-sm lg:[table_>_:last-child_>_tr:last-child_>_&:last-child]:rounded-br-sm";

export const TableHead = ({
  className,
  scope,
  sortDirection,
  onSort,
  children,
  ...props
}: Omit<React.ThHTMLAttributes<HTMLTableCellElement>, "aria-sort"> & {
  sortDirection?: "ascending" | "descending" | "none";
  onSort?: () => void;
}) => {
  const rowGroup = React.useContext(RowGroupContext);
  return (
    <th
      aria-sort={sortDirection}
      scope={scope}
      onClick={onSort}
      className={classNames(
        "px-4 py-3 text-left align-middle lg:table-cell lg:whitespace-nowrap",
        rowGroup === "body" && "lg:border-t lg:border-border",
        cellRoundingClasses,
        scope === "row" && "font-normal",
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
};

export const TableCell = ({
  className,
  hideLabel,
  label,
  children,
  ...props
}: React.TdHTMLAttributes<HTMLTableCellElement> & {
  hideLabel?: boolean;
  label?: React.ReactNode;
}) => {
  const cellContext = React.useContext(TableCellContext);
  return (
    <td
      className={classNames(
        "block p-4 text-left align-middle not-first:border-t not-first:border-border lg:table-cell lg:border-t lg:border-border",
        cellRoundingClasses,
        className,
      )}
      {...props}
    >
      {label || cellContext?.label ? (
        <div className={classNames("mb-2 font-bold lg:hidden", hideLabel && "sr-only relative")}>
          {label ?? cellContext?.label}
        </div>
      ) : null}
      {children}
    </td>
  );
};
