import * as React from "react";

import { Button } from "$app/components/Button";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

export const ExportSalesPopover = () => {
  const [open, setOpen] = React.useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverAnchor>
        <PopoverTrigger asChild>
          <Button>Export all sales</Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent>
        <div className="flex flex-col gap-4">
          <h3>Export all sales</h3>
          <div>You'll get a CSV of every sale you've made. Large exports arrive by email.</div>
          <NavigationButtonInertia
            color="primary"
            href={Routes.export_purchases_path()}
            onSuccess={() => setOpen(false)}
          >
            Export
          </NavigationButtonInertia>
        </div>
      </PopoverContent>
    </Popover>
  );
};
