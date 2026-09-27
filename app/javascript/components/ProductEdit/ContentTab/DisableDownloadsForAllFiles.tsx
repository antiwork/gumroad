import { ArrowInDownSquareHalf } from "@boxicons/react";
import * as React from "react";
import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { PopoverClose } from "$app/components/Popover";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { PopoverMenuItem } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Menu, MenuItem } from "$app/components/ui/Menu";

// Writes through the server: the editor save carries only the files embedded in the version
// being edited, so flipping local state would miss the rest of the product's files.
export const DisableDownloadsForAllFiles = () => {
  const { updateProduct, uniquePermalink } = useProductEditContext();
  const [confirming, setConfirming] = React.useState(false);
  const [working, setWorking] = React.useState(false);

  const disableAll = async () => {
    setWorking(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.disable_downloads_for_all_files_link_path(uniquePermalink),
        accept: "json",
      });
      if (!response.ok) throw new ResponseError();
      const { disabled_count, disabled_file_ids, ineligible_count } = typia.assert<{
        disabled_count: number;
        disabled_file_ids: string[];
        ineligible_count: number;
      }>(await response.json());

      // Mirror the exact set the server wrote: leaving stream_only: false in the file state
      // would let the next save send the old value back and silently re-enable downloads.
      const disabledIds = new Set(disabled_file_ids);
      updateProduct((product) => {
        product.files = product.files.map((file) => (disabledIds.has(file.id) ? { ...file, stream_only: true } : file));
      });

      const fileCount = (count: number) => `${count} file${count === 1 ? "" : "s"}`;
      const details = [
        disabled_count > 0
          ? `Downloads are now off for ${fileCount(disabled_count)}.`
          : "Every file that can have downloads off already does.",
        ineligible_count > 0
          ? `${fileCount(ineligible_count)} stay${ineligible_count === 1 ? "s" : ""} downloadable, because the browser can't open ${ineligible_count === 1 ? "it" : "them"} for your buyers.`
          : null,
      ].filter((detail) => detail !== null);
      showAlert(details.join(" "), disabled_count > 0 ? "success" : "info");
    } catch (error) {
      showAlert(error instanceof Error ? error.message : "Could not disable downloads.", "error");
    } finally {
      setWorking(false);
      setConfirming(false);
    }
  };

  return (
    <>
      <PopoverMenuItem name="File downloads" icon={<ArrowInDownSquareHalf className="size-5" />}>
        <Menu aria-label="File download settings">
          <PopoverClose asChild>
            <MenuItem onClick={() => setConfirming(true)}>
              <span>Disable downloads for all files</span>
            </MenuItem>
          </PopoverClose>
        </Menu>
      </PopoverMenuItem>
      {confirming ? (
        <Modal
          open
          onClose={() => setConfirming(false)}
          title="Disable downloads for all files?"
          footer={
            <>
              <Button onClick={() => setConfirming(false)}>No, cancel</Button>
              <Button color="danger" disabled={working} onClick={() => void disableAll()}>
                Yes, disable downloads
              </Button>
            </>
          }
        >
          <p>
            Every file your buyers can open in the browser — videos in the player and documents in the reader — stops
            offering a download.
          </p>
          <p>
            This applies to buyers who already purchased, so their download links stop working too. Files with no
            in-browser viewer, such as ZIPs, keep their download button. You can turn downloads back on for a single
            file from that file's settings.
          </p>
        </Modal>
      ) : null}
    </>
  );
};
