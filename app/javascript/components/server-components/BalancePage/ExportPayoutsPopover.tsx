import * as React from "react";

import { ExportablePayout, exportPayouts, getExportablePayouts } from "$app/data/balance";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

const ExportPayoutsPopoverContent = ({ closePopover }: { closePopover: () => void }) => {
  const currentYear = new Date().getFullYear();
  const [yearsWithPayouts, setYearsWithPayouts] = React.useState<number[]>([currentYear]);
  const [selectedYear, setSelectedYear] = React.useState<number>(currentYear);

  const [payouts, setPayouts] = React.useState<ExportablePayout[]>([]);
  const [selectedPayouts, setSelectedPayouts] = React.useState<Set<string>>(new Set());

  const [isLoading, setIsLoading] = React.useState(true);
  const [isDownloading, setIsDownloading] = React.useState(false);

  const loadExportablePayouts = async (year: number) => {
    setIsLoading(true);
    const { selected_year, years_with_payouts, payouts_in_selected_year } = await getExportablePayouts(year);
    setSelectedYear(selected_year);
    setYearsWithPayouts(years_with_payouts);
    setPayouts(payouts_in_selected_year);
    setSelectedPayouts(new Set());
    setIsLoading(false);
  };

  useRunOnce(() => void loadExportablePayouts(currentYear));

  const handleYearChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    setSelectedYear(Number(e.target.value));
    void loadExportablePayouts(Number(e.target.value));
  };

  const toggleSelectAll = () => {
    setSelectedPayouts((prevSelected) => {
      if (prevSelected.size === payouts.length) {
        return new Set();
      }
      return new Set(payouts.map((payout) => payout.id));
    });
  };

  const toggleSelectOne = (id: string) => {
    setSelectedPayouts((prevSelected) => {
      const newSelected = new Set(prevSelected);
      if (newSelected.has(id)) {
        newSelected.delete(id);
      } else {
        newSelected.add(id);
      }
      return newSelected;
    });
  };

  const handleDownload = asyncVoid(async () => {
    setIsDownloading(true);

    try {
      await exportPayouts(Array.from(selectedPayouts));
      closePopover();
      showAlert("You will receive an email in your inbox shortly with the data you've requested.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }

    setIsDownloading(false);
  });

  return (
    <div className="max-w-[300px] space-y-4">
      <header>
        <p className="mb-1">
          <strong>Export multiple payouts</strong>
        </p>
        <p>Select multiple payout periods to download their CSV files at once.</p>
      </header>

      <section>
        <select
          aria-label="Filter by year"
          value={selectedYear}
          onChange={handleYearChange}
          className="w-full"
          disabled={isLoading || isDownloading}
        >
          {yearsWithPayouts.map((year) => (
            <option key={year} value={year}>
              {year}
            </option>
          ))}
        </select>
      </section>

      <section className="relative -mx-4 max-h-[300px] max-w-none overflow-y-auto border-y p-4">
        {isLoading ? (
          <div className="absolute inset-0 z-10 flex items-center justify-center bg-white/50">
            <LoadingSpinner width="2em" />
          </div>
        ) : null}
        <div className="space-y-2">
          {payouts.length === 0 ? (
            <p>No payouts found for this year.</p>
          ) : (
            payouts.map((payout) => (
              <label key={payout.id} className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={selectedPayouts.has(payout.id)}
                  onChange={() => toggleSelectOne(payout.id)}
                  disabled={isLoading || isDownloading}
                />
                {payout.date_formatted}
              </label>
            ))
          )}
        </div>
      </section>

      <footer className="flex gap-2">
        <Button
          onClick={toggleSelectAll}
          className="flex-1"
          disabled={isLoading || isDownloading || payouts.length === 0}
        >
          {payouts.length && selectedPayouts.size === payouts.length ? "Deselect all" : "Select all"}
        </Button>
        <Button
          color="primary"
          onClick={handleDownload}
          disabled={selectedPayouts.size === 0 || isLoading || isDownloading}
          className="flex-1"
        >
          {isDownloading ? <LoadingSpinner /> : "Download"}
        </Button>
      </footer>
    </div>
  );
};

export const ExportPayoutsPopover = () => {
  const [isOpen, setIsOpen] = React.useState(false);

  const closePopover = () => {
    setIsOpen(false);
  };

  return (
    <Popover
      aria-label="Bulk export"
      open={isOpen}
      onToggle={setIsOpen}
      trigger={
        <Button aria-label="Bulk export">
          <Icon name="download" />
        </Button>
      }
    >
      {isOpen ? <ExportPayoutsPopoverContent closePopover={closePopover} /> : null}
    </Popover>
  );
};
