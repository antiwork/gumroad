import * as React from "react";

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
    event.preventDefault();
    dispatchClose();
  };

  return (
    <dialog
      open={supportsNative ? undefined : open}
      ref={ref}
      onClick={(e) => {
        if (!ref.current) return;
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
        <h2 id={id}>
          {title}
          {allowClose ? <button type="button" className="close" aria-label="Close" onClick={dispatchClose} /> : null}
        </h2>
      ) : null}
      {children}
      {footer ? <footer>{footer}</footer> : null}
    </dialog>
  );
};
