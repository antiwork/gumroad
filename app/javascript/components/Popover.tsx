import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Details } from "$app/components/Details";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

export type Props = {
  trigger: React.ReactNode | ((open: boolean) => React.ReactNode);
  children: React.ReactNode | ((close: () => void) => React.ReactNode);
  className?: string;
  dropdownClassName?: string;
  open?: boolean;
  onToggle?: (open: boolean) => void;
  style?: React.CSSProperties;
  position?: "top" | "bottom" | undefined;
  "aria-label"?: string;
  disabled?: boolean;
};

export const Popover = ({
  trigger,
  children,
  className: triggerClassName,
  dropdownClassName,
  open: openProp,
  onToggle,
  style,
  position,
  "aria-label": ariaLabel,
  disabled,
}: Props) => {
  const [open, setOpen] = React.useState(openProp ?? false);
  const ref = React.useRef<HTMLElement | null>(null);

  if (openProp !== undefined && open !== openProp) setOpen(openProp);

  const toggle = (newOpen: boolean) => {
    if (openProp === undefined) setOpen(newOpen);
    if (newOpen !== open) onToggle?.(newOpen);
  };

  useOnOutsideClick([ref.current], () => toggle(false));
  useGlobalEventListener("keydown", (evt) => {
    if (evt.key === "Escape") {
      toggle(false);
    }
  });
  const dropoverPosition = useDropdownPosition(ref);
  React.useEffect(() => {
    if (!open) return;
    const focusElement = ref.current?.querySelector("[autofocus]");
    if (focusElement instanceof HTMLElement) focusElement.focus();
  }, [open]);

  const renderedTrigger = typeof trigger === "function" ? trigger(open) : trigger;

  return (
    <Details
      className={classNames("popover toggle", position, triggerClassName)}
      summary={renderedTrigger}
      summaryProps={{
        inert: disabled,
        "aria-label": ariaLabel,
        "aria-haspopup": true,
        "aria-expanded": open,
      }}
      open={open}
      onToggle={toggle}
      ref={(el) => (ref.current = el)}
      style={style}
    >
      <div className={classNames("dropdown", dropdownClassName)} style={dropoverPosition}>
        {children instanceof Function ? children(() => toggle(false)) : children}
      </div>
    </Details>
  );
};

export const useDropdownPosition = (ref: React.RefObject<HTMLElement>) => {
  const [space, setSpace] = React.useState(0);
  const [maxWidth, setMaxWidth] = React.useState(0);
  React.useEffect(() => {
    const calculateSpace = () => {
      if (!ref.current?.parentElement) return;
      let scrollContainer = ref.current.parentElement;
      while (getComputedStyle(scrollContainer).overflow === "visible" && scrollContainer.parentElement !== null) {
        scrollContainer = scrollContainer.parentElement;
      }
      setSpace(
        scrollContainer.clientWidth -
          (ref.current.getBoundingClientRect().left - scrollContainer.getBoundingClientRect().left),
      );
      setMaxWidth(scrollContainer.clientWidth);
    };
    calculateSpace();
    window.addEventListener("resize", calculateSpace);

    return () => window.removeEventListener("resize", calculateSpace);
  });

  return {
    translate: `min(${space}px - 100% - var(--spacer-4), 0px)`,
    maxWidth: `calc(${maxWidth}px - 2 * var(--spacer-4))`,
  };
};
