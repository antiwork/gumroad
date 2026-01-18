import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Sheet = ({
  children,
  className,
  modal = false,
  ...props
}: { className?: string; modal?: boolean } & React.ComponentProps<typeof Dialog.Root>) => (
  <Dialog.Root {...props} modal={modal}>
    <Dialog.Portal>
      {modal ? <Dialog.Overlay className="fixed inset-0 z-40 bg-black/80" /> : null}
      <Dialog.Content
        className={classNames(
          "bg-filled fixed inset-0 z-40 flex flex-col gap-4 overflow-auto border-border p-6 md:left-[unset] md:w-[40vw] md:border-l",
          className,
        )}
        aria-modal
        onPointerDownOutside={(e) => {
          if (!modal) e.preventDefault();
        }}
      >
        {children}
      </Dialog.Content>
    </Dialog.Portal>
  </Dialog.Root>
);
export const SheetHeader = ({ children }: { children: React.ReactNode }) => (
  <div className="flex items-start gap-4">
    <Dialog.Title>{children}</Dialog.Title>
    <Dialog.Close className="ml-auto cursor-pointer all-unset" aria-label="Close">
      <Icon name="x" />
    </Dialog.Close>
  </div>
);
