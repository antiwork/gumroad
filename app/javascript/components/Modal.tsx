import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Modal = ({
  open,
  title,
  children,
  footer,
  allowClose = true,
  onClose,
  modal = true,
}: {
  open: boolean;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  allowClose?: boolean;
  onClose?: () => void;
  modal?: boolean;
}) => {
  const dispatchClose = () => allowClose && onClose?.();
  const ref = React.useRef<HTMLDialogElement | null>(null);
  const [supportsNative, setSupportsNative] = React.useState(false);
  React.useEffect(() => {
    if (!ref.current || !modal) return;
    if (supportsNative) {
      if (open) ref.current.showModal();
      else ref.current.close();
    }
    if ("showModal" in ref.current) setSupportsNative(true);
  }, [open, supportsNative]);

  const id = React.useId();

  const handleCancel = (event: React.SyntheticEvent<HTMLDialogElement>) => {
    if (event.target === ref.current) {
      event.preventDefault();
      dispatchClose();
    }
  };

  return (
    <dialog
      className={classNames(
        "bg-filled fixed top-[50%] left-[50%] z-31 flex max-w-175 min-w-80 translate-[-50%] flex-col gap-4 rounded border border-border p-8 shadow-lg backdrop:bg-black/80 dark:shadow-none",
        { hidden: !open },
      )}
      open={supportsNative ? undefined : open}
      ref={ref}
      onClick={(e) => {
        if (!ref.current || !modal) return;
        if (!e.nativeEvent.isTrusted) return; // Indicates a synthetic event
        const bounds = ref.current.getBoundingClientRect();
        if (e.clientX < bounds.x || e.clientY < bounds.y || e.clientX > bounds.right || e.clientY > bounds.bottom)
          dispatchClose();
      }}
      onCancel={handleCancel}
      onKeyDown={(e) => {
        // In Chrome, Escape doesn't correctly call the cancel event sometimes, but closes the dialog anyway.
        // Handling Escape presses explicitly works around that.
        if (e.key === "Escape" && modal) handleCancel(e);
      }}
      aria-labelledby={id}
    >
      {title ? (
        <h2 id={id} className="flex items-start justify-between gap-4">
          {title}
          {allowClose ? (
            <button type="button" className="text-base" aria-label="Close" onClick={dispatchClose}>
              <Icon name="x" />
            </button>
          ) : null}
        </h2>
      ) : null}
      {children}
      {footer ? <footer className="grid gap-4 sm:flex sm:justify-end">{footer}</footer> : null}
    </dialog>
  );
};
