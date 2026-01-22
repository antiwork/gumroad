import { usePage } from "@inertiajs/react";
import * as React from "react";

import AdminSalesReportsForm from "$app/components/Admin/SalesReports/Form";
import { buttonVariants } from "$app/components/Button";
import { Popover } from "$app/components/Popover";
import { WithTooltip } from "$app/components/WithTooltip";

type PageProps = {
  countries: [string, string][];
  sales_types: [string, string][];
  authenticity_token: string;
};

const NewSalesReportPopover = () => {
  const { countries, sales_types, authenticity_token } = usePage<PageProps>().props;
  const [open, setOpen] = React.useState(false);

  return (
    <Popover
      open={open}
      onToggle={setOpen}
      aria-label="New Sales Report"
      trigger={
        <WithTooltip tip="Generate a new sales report" position="bottom">
          <div className={buttonVariants({ size: "default", color: "primary" })}>New report</div>
        </WithTooltip>
      }
    >
      <div className="grid w-96 max-w-full gap-3">
        <AdminSalesReportsForm
          countries={countries}
          sales_types={sales_types}
          authenticityToken={authenticity_token}
          onSuccess={() => setOpen(false)}
        />
      </div>
    </Popover>
  );
};

export default NewSalesReportPopover;
