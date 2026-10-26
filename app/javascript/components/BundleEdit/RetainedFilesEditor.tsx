import * as React from "react";

import { cast } from "$app/utils/cast";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { FieldsetDescription } from "$app/components/ui/Fieldset";

export type RetainedFile = {
  id: string;
  name: string;
  filetype: string | null;
  size: string | null;
};

type RetainedFilesEditorProps = {
  bundleId: string;
  files: RetainedFile[];
  onRemoved: (id: string) => void;
};

// Files attached to the bundle itself, rather than to a product in it: a converted bundle keeps the
// files the product had, they ship to buyers, and no other bundle surface lists them.
export const RetainedFilesEditor = ({ bundleId, files, onRemoved }: RetainedFilesEditorProps) => {
  const [pendingRemoval, setPendingRemoval] = React.useState<RetainedFile | null>(null);
  const [isRemoving, setIsRemoving] = React.useState(false);

  if (files.length === 0) return null;

  const removeFile = async (file: RetainedFile) => {
    setIsRemoving(true);

    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.remove_file_bundle_product_path(bundleId),
        data: { file_id: file.id },
      });
      const json = cast<{ success?: boolean; message?: string; error_message?: string }>(await response.json());
      if (!response.ok || json.success === false) throw new ResponseError(json.message ?? json.error_message);

      setPendingRemoval(null);
      onRemoved(file.id);
      showAlert("File removed.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsRemoving(false);
    }
  };

  const describe = (file: RetainedFile) => [file.filetype?.toUpperCase(), file.size].filter(Boolean).join(" · ");

  return (
    <section className="grid gap-8 border-t border-border p-4 md:p-8">
      <div className="grid gap-2">
        <h2>Files</h2>
        <FieldsetDescription>
          Every buyer gets these files along with the products in this bundle. A product converted into a bundle keeps
          the files it had.
        </FieldsetDescription>
      </div>
      <ul className="grid gap-3">
        {files.map((file) => (
          <li key={file.id} className="flex flex-wrap items-center justify-between gap-3">
            <div className="grid gap-1">
              <span>{file.name}</span>
              {describe(file) ? <span className="text-sm text-muted">{describe(file)}</span> : null}
            </div>
            <Button aria-label={`Remove ${file.name}`} onClick={() => setPendingRemoval(file)}>
              Remove
            </Button>
          </li>
        ))}
      </ul>
      {pendingRemoval ? (
        <Modal
          open
          allowClose={!isRemoving}
          onClose={() => setPendingRemoval(null)}
          title="Remove this file?"
          footer={
            <>
              <Button disabled={isRemoving} onClick={() => setPendingRemoval(null)}>
                Cancel
              </Button>
              <Button color="danger" disabled={isRemoving} onClick={() => void removeFile(pendingRemoval)}>
                {isRemoving ? "Removing..." : "Remove"}
              </Button>
            </>
          }
        >
          Buyers will no longer receive {pendingRemoval.name}. The products in this bundle are not affected, and you
          can't undo this.
        </Modal>
      ) : null}
    </section>
  );
};
