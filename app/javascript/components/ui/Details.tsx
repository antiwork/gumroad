import { ChevronDown, ChevronRight } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

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
  const Chevron = isOpen ? ChevronDown : ChevronRight;

  return (
    <summary
      ref={ref}
      className={classNames(
        "flex cursor-pointer items-center [&::-webkit-details-marker]:hidden [&::marker]:hidden",
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
      {chevronPosition === "left" ? <Chevron className="mr-1 size-5 shrink-0" /> : null}
      {children}
      {chevronPosition === "right" ? <Chevron className="col-start-2 ml-auto size-5 shrink-0" /> : null}
    </summary>
  );
});
DetailsToggle.displayName = "DetailsToggle";
