import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { LinkButton } from "$app/components/ui/LinkButton";

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

// On a phone a row is a card, not a table row: the first cell is its title, and the rest sit two
// to a line under it as small label-and-value pairs. A cell with no label (a thumbnail, a row's
// buttons) takes a full line unless its own classes say otherwise.
const TableCellContext = React.createContext<{ label?: React.ReactNode; primary: boolean } | null>(null);

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
    () => React.Children.map(children, (_, index) => ({ label: headers?.[index], primary: index === 0 })) ?? [],
    [children, headers],
  );

  return (
    <tr
      aria-selected={selected}
      className={classNames(
        "flex flex-wrap items-start gap-x-4 gap-y-3 rounded-sm border border-border p-4 lg:table-row",
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
  const SortLabel = sortDirection && (onSort || props.onClick) ? LinkButton : "span";
  return (
    <th
      aria-sort={sortDirection}
      scope={scope}
      onClick={onSort}
      className={classNames(
        "px-4 py-3 text-left align-middle lg:table-cell lg:whitespace-nowrap",
        rowGroup === "body" && "max-lg:basis-full max-lg:p-0 lg:border-t lg:border-border",
        cellRoundingClasses,
        scope === "row" && "font-normal",
        sortDirection && "cursor-pointer",
        className,
      )}
      {...props}
    >
      <SortLabel className="inline-flex items-center gap-1 no-underline! focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent">
        {children}
        {sortDirection && sortDirection !== "none" ? (
          <span className="inline-block" aria-hidden="true">
            {sortDirection === "ascending" ? "↑" : "↓"}
          </span>
        ) : null}
      </SortLabel>
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
  const cellLabel = label ?? cellContext?.label;
  // The card's title needs no label: it is the first thing in the card, and says what it is.
  const primary = cellContext?.primary === true && !!cellLabel;
  return (
    <td
      className={classNames(
        "block min-w-0 grow text-left align-middle lg:table-cell lg:border-t lg:border-border lg:p-4",
        cellLabel && !hideLabel && !primary ? "basis-[calc(50%-0.5rem)]" : "basis-full",
        primary && "max-lg:font-bold",
        // The cell after a thumbnail shares its line: the full width less the thumbnail and the gap.
        "max-lg:[[data-thumbnail]+&]:basis-[calc(100%-4rem)]",
        cellRoundingClasses,
        className,
      )}
      {...props}
    >
      {cellLabel ? (
        <div className={classNames("mb-1 text-sm lg:hidden", (hideLabel || primary) && "sr-only relative")}>
          {cellLabel}
        </div>
      ) : null}
      {children}
    </td>
  );
};
