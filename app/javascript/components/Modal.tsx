import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Modal = ({
  className,
  title,
  children,
  footer,
  allowClose = true,
  onClose,
  modal = true,
  usePortal,
  ...props
}: {
  className?: string;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  allowClose?: boolean;
  usePortal?: boolean;
  onClose?: () => void;
} & Omit<React.ComponentProps<typeof Dialog.Root>, "onOpenChange">) => {
  const content = (
    <>
      <Dialog.Content
        aria-modal={modal}
        className={classNames(
          "bg-filled fixed top-[50%] left-[50%] z-31 flex max-h-[90vh] max-w-175 min-w-80 translate-[-50%] flex-col gap-4 overflow-y-auto rounded border border-border p-8 shadow-lg dark:shadow-none",
          className,
        )}
        onOpenAutoFocus={(e) => {
          if (!modal) e.preventDefault();
        }}
      >
        {title ? (
          <div className="flex items-start justify-between gap-4">
            <Dialog.Title>{title}</Dialog.Title>
            {allowClose ? (
              <Dialog.Close className="text-base" aria-label="Close">
                <Icon name="x" />
              </Dialog.Close>
            ) : null}
          </div>
        ) : null}
        {children}
        {footer ? <footer className="grid gap-4 sm:flex sm:justify-end">{footer}</footer> : null}
      </Dialog.Content>
      <Dialog.Overlay className="fixed inset-0 z-30 bg-backdrop" />
    </>
  );

  return (
    <Dialog.Root onOpenChange={() => onClose?.()} modal={modal} {...props}>
      {usePortal ? <Dialog.Portal>{content}</Dialog.Portal> : content}
    </Dialog.Root>
  );
};
