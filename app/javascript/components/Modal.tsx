import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { Icon } from "$app/components/Icons";

export const Modal = ({
  title,
  children,
  footer,
  allowClose = true,
  onClose,
  modal = true,
  ...props
}: {
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  allowClose?: boolean;
  onClose?: () => void;
} & Omit<React.ComponentProps<typeof Dialog.Root>, "onOpenChange">) => (
  <Dialog.Root onOpenChange={() => onClose?.()} modal={modal} {...props}>
    <Dialog.Content
      aria-modal={modal}
      className="bg-filled fixed top-[50%] left-[50%] z-31 flex max-w-175 min-w-80 translate-[-50%] flex-col gap-4 rounded border border-border p-8 shadow-lg dark:shadow-none"
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
    <Dialog.Overlay className="fixed inset-0 z-30 bg-black/80" />
  </Dialog.Root>
);
