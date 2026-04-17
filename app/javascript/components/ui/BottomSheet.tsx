import { X } from "@boxicons/react";
import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { Button } from "$app/components/Button";

export const BottomSheet = ({ children, ...props }: React.ComponentProps<typeof Dialog.Root>) => (
  <Dialog.Root {...props} modal>
    <Dialog.Portal>
      <Dialog.Overlay className="fixed inset-0 z-40 bg-black/80" />
      <Dialog.Content aria-describedby={undefined} className="fixed inset-x-0 bottom-0 z-40 flex max-h-[85vh] flex-col gap-4 overflow-auto rounded-t border-t border-border bg-background p-6">
        {children}
      </Dialog.Content>
    </Dialog.Portal>
  </Dialog.Root>
);

export const BottomSheetHeader = ({ children }: { children: React.ReactNode }) => (
  <div className="flex items-center gap-4">
    <Dialog.Title>{children}</Dialog.Title>
    <Dialog.Close className="ml-auto cursor-pointer all-unset" aria-label="Close">
      <X className="size-5" />
    </Dialog.Close>
  </div>
);

export const BottomSheetFooter = ({ children }: { children?: React.ReactNode }) => (
  <div className="flex items-center justify-end gap-4 pt-2">
    {children}
    <Dialog.Close asChild>
      <Button color="primary">Done</Button>
    </Dialog.Close>
  </div>
);
