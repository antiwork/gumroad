import { X } from "@boxicons/react";
import * as React from "react";

import { cast } from "$app/utils/cast";
import { assertResponseError, RateLimitError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { FieldsetDescription } from "$app/components/ui/Fieldset";

export type RetainedFile = {
  id: string;
  name: string;
  filetype: string | null;
  size: string | null;
};

const UNCONFIRMED_REMOVAL_MESSAGE = "We couldn't confirm the file was removed. Refresh the page to check.";

type RetainedFilesEditorProps = {
  bundleId: string;
  files: RetainedFile[];
  onRemoved: (id: string) => void;
};

// Files a converted bundle kept; they ship with the bundle and no other surface lists them.
export const RetainedFilesEditor = ({ bundleId, files, onRemoved }: RetainedFilesEditorProps) => {
  const [pendingRemoval, setPendingRemoval] = React.useState<RetainedFile | null>(null);
  const [isRemoving, setIsRemoving] = React.useState(false);
  // Shown next to the list rather than as a page toast, and kept until dismissed: the row it replaces is gone.
  const [removedName, setRemovedName] = React.useState<string | null>(null);
  const headingId = React.useId();

  if (files.length === 0 && removedName === null) return null;

  const removeFile = async (file: RetainedFile) => {
    setIsRemoving(true);
    setRemovedName(null);

    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.remove_file_bundle_product_path(bundleId),
        data: { file_id: file.id },
      });
      const json = cast<{ success?: boolean; error_message?: string; error?: string }>(
        await response.json().catch(() => ({})),
      );
      if (response.ok && json.success === true) {
        onRemoved(file.id);
        setRemovedName(file.name);
      } else {
        // JSON refusals (Pundit's uses `error`) precede any write or follow its rollback; anything else is unconfirmed.
        const refusal = response.ok ? null : (json.error_message ?? json.error ?? null);
        showAlert(refusal ?? UNCONFIRMED_REMOVAL_MESSAGE, "error");
      }
    } catch (e) {
      assertResponseError(e);
      // request() throws on 5xx and lost connections, which can follow a committed deletion; a 429 is refused up front.
      showAlert(e instanceof RateLimitError ? e.message : UNCONFIRMED_REMOVAL_MESSAGE, "error");
    } finally {
      setIsRemoving(false);
      setPendingRemoval(null);
    }
  };

  const describe = (file: RetainedFile) => [file.filetype?.toUpperCase(), file.size].filter(Boolean).join(" · ");

  return (
    <section className="grid gap-8 border-t border-border p-4 md:p-8">
      <div className="grid gap-2">
        <h2 id={headingId}>Files</h2>
        <FieldsetDescription>
          Every buyer gets these files along with the products in this bundle. A product converted into a bundle keeps
          the files it had.
        </FieldsetDescription>
      </div>
      {/* Mounted before any removal so the confirmation lands in an existing live region and is announced. */}
      <div role="status" className="contents">
        {removedName !== null ? (
          <Alert role="none" variant="success">
            <div className="flex items-start gap-2">
              <span className="min-w-0 flex-1 [overflow-wrap:anywhere]">Removed {removedName}.</span>
              <button
                type="button"
                aria-label="Dismiss"
                className="relative flex size-[1lh] shrink-0 cursor-pointer items-center justify-center text-muted all-unset before:absolute before:-inset-2 before:content-[''] hover:text-primary"
                onClick={() => setRemovedName(null)}
              >
                <X className="size-4" />
              </button>
            </div>
          </Alert>
        ) : null}
      </div>
      {files.length > 0 ? (
        <ul aria-labelledby={headingId} className="grid gap-3 pl-0">
          {files.map((file) => (
            <li key={file.id} className="flex items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-1">
                <span className="[overflow-wrap:anywhere]">{file.name}</span>
                {describe(file) ? <span className="text-sm text-muted">{describe(file)}</span> : null}
              </div>
              <Button className="shrink-0" aria-label={`Remove ${file.name}`} onClick={() => setPendingRemoval(file)}>
                Remove
              </Button>
            </li>
          ))}
        </ul>
      ) : null}
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
