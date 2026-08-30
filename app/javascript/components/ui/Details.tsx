import { ChevronRight } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

const chevronClassName = (isOpen: boolean, extra?: string) =>
  classNames(
    "size-5 shrink-0 transition-transform duration-200 ease-out motion-reduce:transition-none",
    isOpen && "rotate-90",
    extra,
  );

type DetailsContextValue = {
  isOpen: boolean;
  onToggle?: ((open: boolean) => void) | undefined;
  open?: boolean | undefined;
};

const DetailsContext = React.createContext<DetailsContextValue>({
  isOpen: false,
});

export const useDetails = () => React.useContext(DetailsContext);

export const Details = React.forwardRef<
  HTMLDetailsElement,
  {
    open?: boolean;
    onToggle?: (open: boolean) => void;
  } & Omit<React.ComponentProps<"details">, "onToggle">
>(({ children, open, onToggle, ...props }, ref) => {
  const [internalOpen, setInternalOpen] = React.useState(open ?? false);
  const isOpen = onToggle ? (open ?? false) : internalOpen;

  const contextValue = React.useMemo(() => ({ isOpen, onToggle, open }), [isOpen, onToggle, open]);

  return (
    <DetailsContext.Provider value={contextValue}>
      <details
        open={open}
        ref={ref}
        onToggle={onToggle ? undefined : (e) => setInternalOpen(e.currentTarget.open)}
        {...props}
      >
        {children}
      </details>
    </DetailsContext.Provider>
  );
});
Details.displayName = "Details";

export const DetailsToggle = React.forwardRef<
  HTMLElement,
  {
    chevronPosition?: "left" | "right" | "none";
  } & React.HTMLAttributes<HTMLElement>
>(({ children, className, onClick, chevronPosition = "left", ...props }, ref) => {
  const { isOpen, onToggle, open } = useDetails();

  return (
    <summary
      ref={ref}
      className={classNames(
        "flex cursor-pointer items-center [&::-webkit-details-marker]:hidden [&::marker]:hidden",
        "transition-[margin] duration-200 ease-out motion-reduce:transition-none",
        isOpen && "mb-2",
        className,
      )}
      onClick={(e) => {
        onClick?.(e);
        if (!onToggle) return;
        e.preventDefault();
        e.stopPropagation();
        onToggle(!open);
      }}
      {...props}
    >
      {chevronPosition === "left" ? (
        <ChevronRight aria-hidden="true" className={chevronClassName(isOpen, "mr-1")} />
      ) : null}
      {children}
      {chevronPosition === "right" ? (
        <ChevronRight aria-hidden="true" className={chevronClassName(isOpen, "col-start-2 ml-auto")} />
      ) : null}
    </summary>
  );
});
DetailsToggle.displayName = "DetailsToggle";
