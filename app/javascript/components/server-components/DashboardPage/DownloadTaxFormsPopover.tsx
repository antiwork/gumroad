import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";

type Props = {
  taxForms: Record<number, string>;
};

export const DownloadTaxFormsPopover = ({ taxForms }: Props) => {
  const [isOpen, setIsOpen] = React.useState(false);
  const [selectedYears, setSelectedYears] = React.useState<Set<number>>(new Set());

  const handleDownload = () => {
    try {
      if (selectedYears.size === 0) {
        showAlert("Please select at least one tax year to download.", "error");
        return;
      }
      selectedYears.forEach((year) => {
        window.open(taxForms[year], "_blank", "noopener,noreferrer");
      });
      setIsOpen(false);
    } catch {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  const toggleSelectAll = () => {
    setSelectedYears((prev) => new Set(prev.size === Object.keys(taxForms).length ? [] : Object.keys(taxForms)));
  };

  return (
    <Popover
      aria-label="Download tax forms"
      open={isOpen}
      onOpenChange={(open) => {
        setIsOpen(open);
        if (open) setSelectedYears(new Set());
      }}
    >
      <PopoverAnchor>
        <PopoverTrigger aria-label="Tax forms" asChild>
          <Button>
            Tax forms
            <Icon name="download" />
          </Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent sideOffset={4}>
        <div className="max-w-[300px] space-y-4 sm:max-w-full">
          {Object.keys(taxForms).length === 0 ? (
            <section className="text-muted">No tax forms available.</section>
          ) : (
            <>
              <header>
                <p className="mb-1">
                  <strong>Download tax forms</strong>
                </p>
                <p>Select the tax years you want to download.</p>
              </header>

              <section className="relative -mx-4 max-h-[300px] max-w-none overflow-y-auto border-b p-4">
                <fieldset>
                  {Object.keys(taxForms)
                    .sort((a, b) => Number(b) - Number(a))
                    .map((year) => (
                      <label key={year}>
                        <input
                          type="checkbox"
                          checked={selectedYears.has(year)}
                          onChange={(event) => {
                            const newSelectedYears = new Set(selectedYears);
                            if (event.target.checked) {
                              newSelectedYears.add(year);
                            } else {
                              newSelectedYears.delete(year);
                            }
                            setSelectedYears(newSelectedYears);
                          }}
                        />
                        {year}
                      </label>
                    ))}
                </fieldset>
              </section>

              <footer className="flex gap-4">
                <Button className="flex-1" onClick={toggleSelectAll}>
                  {selectedYears.size === Object.keys(taxForms).length ? "Deselect all" : "Select all"}
                </Button>
                <Button className="flex-1" color="primary" disabled={selectedYears.size === 0} onClick={handleDownload}>
                  Download
                </Button>
              </footer>
            </>
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
};
