import * as React from "react";

import { sendSubscribersReport } from "$app/data/audience";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { PopoverClose } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Label } from "$app/components/ui/Label";

export const ExportSubscribersPopover = () => {
  const [loading, setLoading] = React.useState(false);
  const [followers, setFollowers] = React.useState(true);
  const [customers, setCustomers] = React.useState(false);
  const [affiliates, setAffiliates] = React.useState(false);

  const handleDownload = async () => {
    try {
      setLoading(true);
      await sendSubscribersReport({
        options: {
          followers,
          customers,
          affiliates,
        },
      });

      showAlert("Your export is being prepared. You’ll receive an email with the download link shortly.", "success");
    } catch (error) {
      assertResponseError(error);
      showAlert("Something went wrong.", "error");
    }

    setLoading(false);
  };

  const noOptionSelected = !followers && !customers && !affiliates;
  const allSelected = followers && customers && affiliates;

  const selectAll = () => {
    setFollowers(!allSelected);
    setCustomers(!allSelected);
    setAffiliates(!allSelected);
  };

  return (
    <div>
      <h4 className="mb-1 font-semibold">Download subscribers as CSV</h4>
      <p className="mb-4">This will download a CSV file with one row per subscriber.</p>

      <div className="mb-4 flex flex-col gap-2">
        <Label className="font-medium">
          <Checkbox checked={allSelected} onChange={selectAll} />
          All Subscribers
        </Label>
        <Label>
          <Checkbox
            checked={followers}
            onChange={(evt) => {
              setFollowers(evt.target.checked);
            }}
          />
          Followers
        </Label>
        <Label>
          <Checkbox
            checked={customers}
            onChange={(evt) => {
              setCustomers(evt.target.checked);
            }}
          />
          Customers
        </Label>
        <Label>
          <Checkbox
            checked={affiliates}
            onChange={(evt) => {
              setAffiliates(evt.target.checked);
            }}
          />
          Affiliates
        </Label>
      </div>
      <div className="grid">
        <PopoverClose asChild>
          <Button disabled={noOptionSelected || loading} onClick={() => void handleDownload()}>
            {loading ? <LoadingSpinner color="grey" /> : "Download"}
          </Button>
        </PopoverClose>
      </div>
    </div>
  );
};
