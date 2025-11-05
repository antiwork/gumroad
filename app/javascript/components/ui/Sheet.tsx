import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { Icon } from "$app/components/Icons";

export const Sheet = ({
  children,
  className,
  ...props
}: { className?: string } & React.ComponentProps<typeof Dialog.Root>) => (
  <Dialog.Root {...props}>
    <Dialog.Portal>
      <Dialog.Content className="bg-filled fixed inset-y-0 right-0 z-40 flex w-[40vw] flex-col gap-4 overflow-auto p-6">
        <Dialog.Close className="absolute top-4 right-4">
          <Icon name="x" />
        </Dialog.Close>
        {children}
      </Dialog.Content>
      <Dialog.Overlay className="fixed inset-0 z-30 bg-backdrop" />
    </Dialog.Portal>
  </Dialog.Root>
);
