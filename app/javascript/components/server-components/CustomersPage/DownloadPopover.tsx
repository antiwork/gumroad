import { lightFormat, subMonths } from "date-fns";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = { authenticityToken: string };
export const DownloadPopover = ({ authenticityToken }: Props) => {
  const [from, setFrom] = React.useState(subMonths(new Date(), 1));
  const [to, setTo] = React.useState(new Date());
  return (
    <Popover>
      <WithTooltip tip="Export" position="bottom">
        <PopoverTrigger aria-label="Export" className="js-toggle-download-box" asChild>
          <Button>
            <Icon name="download" />
          </Button>
        </PopoverTrigger>
      </WithTooltip>
      <PopoverContent sideOffset={4}>
        <form
          id="customer-csv-download-form"
          className="js-download-box customer-popover--export grid gap-3"
          action={Routes.export_purchases_path({ format: "csv" })}
          acceptCharset="UTF-8"
          method="post"
        >
          <input type="hidden" name="utf8" value="✓" />
          <input type="hidden" name="authenticity_token" value={authenticityToken} />
          <input type="hidden" name="start_time" id="start_time" value={lightFormat(from, "yyyy-MM-dd")} />
          <input type="hidden" name="end_time" id="end_time" value={lightFormat(to, "yyyy-MM-dd")} />
          <input type="hidden" name="products_and_variants" id="products_and_variants" />

          <div>
            <h3>Download sales as CSV</h3>
            <div className="js-download-customers-as-csv-modal-body">
              This will download a CSV with each purchase on its own row.
            </div>
          </div>
          <DateRangePicker from={from} to={to} setFrom={setFrom} setTo={setTo} />
          <Button type="submit" color="primary">
            Download
          </Button>
        </form>
      </PopoverContent>
    </Popover>
  );
};

export default register({ component: DownloadPopover, propParser: createCast() });
