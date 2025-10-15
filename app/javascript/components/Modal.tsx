import * as React from "react";
import { classNames } from "$app/utils/classNames";

export const Modal = ({
  open,
  title,
  children,
  footer,
  allowClose = true,
  onClose,
}: {
  open: boolean;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  allowClose?: boolean;
  onClose?: () => void;
}) => {
  const dispatchClose = () => allowClose && onClose?.();
  const ref = React.useRef<HTMLDialogElement | null>(null);
  const [supportsNative, setSupportsNative] = React.useState(false);
  React.useEffect(() => {
    if (!ref.current) return;
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
      className={classNames("bg-background text-foreground",
        "border-solid border border-border rounded-sm",
        "shadow-lg shadow-foreground",
        "p-8 flex flex-col fixed top-1/2 left-1/2 -translate-1/2 -translate-y-1/2",
        "z-20 w-fit min-w-xs max-w-[43.75rem] gap-4",
        "dark:shadow-none",
        "backdrop:bg-black/80 not-open:hidden"
      )}
      open={supportsNative ? undefined : open}
      ref={ref}
      onClick={(e) => {
        if (!ref.current) return;
        if (!e.nativeEvent.isTrusted) return; // Indicates a synthetic event
        const bounds = ref.current.getBoundingClientRect();
        if (e.clientX < bounds.x || e.clientY < bounds.y || e.clientX > bounds.right || e.clientY > bounds.bottom)
          dispatchClose();
      }}
      onCancel={handleCancel}
      onKeyDown={(e) => {
        // In Chrome, Escape doesn't correctly call the cancel event sometimes, but closes the dialog anyway.
        // Handling Escape presses explicitly works around that.
        if (e.key === "Escape") handleCancel(e);
      }}
      aria-labelledby={id}
    >
      {title ? (
        <h2 id={id} className={classNames("flex justify-between gap-4 items-start")}>
          {title}
          {allowClose ? <button type="button" className={classNames("text-base/[1.4rem] after:text-base after:content-['\00a0'] after:inline after:bg-current after:min-h-[max(1lh,1em)] after:w-[1em] after:mask-center after:mask-size-[120%] after:mask-no-repeat after:shrink-0")} aria-label="Close" onClick={dispatchClose} /> : null}
        </h2>
      ) : null}
      {children}
      {footer ? <footer className={classNames("grid gap-4 sm:flex sm:justify-end")}>{footer}</footer> : null}
    </dialog>
  );
};
