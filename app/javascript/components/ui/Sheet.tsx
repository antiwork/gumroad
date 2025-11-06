import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Sheet = ({
  children,
  className,
  title,
  ...props
}: { className?: string; title?: React.ReactNode } & React.ComponentProps<typeof Dialog.Root>) => (
  <Dialog.Root {...props}>
    <Dialog.Portal>
      <Dialog.Content
        className={classNames(
          "bg-filled fixed inset-0 z-40 flex flex-col gap-4 overflow-auto border-border p-6 md:left-[unset] md:w-[40vw] md:border-l",
          className,
        )}
        aria-modal
      >
        <div className="flex items-start gap-4">
          {title ? <Dialog.Title>{title}</Dialog.Title> : null}
          <Dialog.Close className="ml-auto" aria-label="Close">
            <Icon name="x" />
          </Dialog.Close>
        </div>
        {children}
      </Dialog.Content>
      <Dialog.Overlay className="fixed inset-0 z-30 bg-backdrop" />
    </Dialog.Portal>
  </Dialog.Root>
);
