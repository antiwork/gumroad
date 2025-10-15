import * as React from "react";
import { createPortal } from "react-dom";
import { classNames } from "$app/utils/classNames";

export const Modal = ({
  open,
  title,
  children,
  footer,
  allowClose = true,
  onClose,
  usePortal = false,
  useNative = true,
}: {
  open: boolean;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  allowClose?: boolean;
  onClose?: () => void;
  usePortal?: boolean;
  useNative?: boolean;
}) => {
  const dispatchClose = () => allowClose && onClose?.();
  const ref = React.useRef<HTMLDialogElement | null>(null);
  const [supportsNative, setSupportsNative] = React.useState(false);

  React.useEffect(() => {
    if (!ref.current) return;

    if (useNative) {
      if (supportsNative) {
        if (open) ref.current.showModal();
        else ref.current.close();
      }
      if ("showModal" in ref.current) setSupportsNative(true);
    }
  }, [open, supportsNative, useNative]);

  const id = React.useId();

  const handleCancel = (event: React.SyntheticEvent<HTMLDialogElement>) => {
    if (event.target === ref.current) {
      event.preventDefault();
      dispatchClose();
    }
  };

  const dialogElement = (
    <dialog
      className={classNames(
        "bg-background text-foreground",
        "border border-border border-solid rounded-sm",
        "shadow-lg shadow-foreground",
        "p-8 flex flex-col fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2",
        "z-20 w-fit min-w-xs max-w-[43.75rem] gap-4",
        "dark:shadow-none",
        "backdrop:bg-black/80 not-open:hidden",
      )}
      open={supportsNative ? undefined : open}
      ref={ref}
      onClick={(e) => {
        if (!ref.current) return;
        if (!e.nativeEvent.isTrusted) return;
        const bounds = ref.current.getBoundingClientRect();
        if (
          e.clientX < bounds.x ||
          e.clientY < bounds.y ||
          e.clientX > bounds.right ||
          e.clientY > bounds.bottom
        )
          dispatchClose();
      }}
      onCancel={handleCancel}
      onKeyDown={(e) => {
        if (e.key === "Escape") handleCancel(e);
      }}
      aria-labelledby={id}
    >
      {title ? (
        <h2 id={id} className="flex justify-between gap-4 items-start">
          {title}
          {allowClose && (
            <button
              type="button"
              aria-label="Close"
              onClick={dispatchClose}
              className={classNames(
                "text-base/[1.4rem]",
                "after:icon-x after:text-base after:content-['\\00a0']",
                "after:inline after:bg-current after:min-h-[max(1lh,1em)] after:w-[1em]",
                "after:[mask-position:50%_50%] after:[mask-size:120%] after:[mask-repeat:no-repeat] after:shrink-0",
              )}
            />
          )}
        </h2>
      ) : null}
      {children}
      {footer && <footer className="grid gap-4 sm:flex sm:justify-end">{footer}</footer>}
    </dialog>
  );

  return usePortal && typeof document !== "undefined"
    ? createPortal(dialogElement, document.body)
    : dialogElement;
};
