import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Icon } from "$app/components/Icons";

export const Sheet = ({
  children,
  className,
  ...props
}: { className?: string } & React.ComponentProps<typeof Dialog.Root>) => (
  <Dialog.Root {...props} modal={false}>
    <Dialog.Portal>
      <Dialog.Content
        className={classNames(
          "bg-filled fixed inset-0 z-40 flex flex-col gap-4 overflow-auto border-border p-6 md:left-[unset] md:w-[40vw] md:border-l",
          className,
        )}
        aria-modal
        onPointerDownOutside={(e) => e.preventDefault()}
      >
        {children}
      </Dialog.Content>
    </Dialog.Portal>
  </Dialog.Root>
);

export const SheetHeader = ({ children }: { children: React.ReactNode }) => (
  <div className="flex items-start gap-4">
    <Dialog.Title>{children}</Dialog.Title>
    <Dialog.Close className="ml-auto" aria-label="Close">
      <Icon name="x" />
    </Dialog.Close>
  </div>
);
