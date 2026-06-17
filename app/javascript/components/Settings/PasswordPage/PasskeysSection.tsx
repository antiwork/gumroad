import { parseISO } from "date-fns";
import * as React from "react";
import typia from "typia";

import { formatDate } from "$app/utils/date";
import { PASSKEY_ADD_ERROR, type Passkey, registerPasskey } from "$app/utils/passkeyRegistration";
import { asyncVoid } from "$app/utils/promise";
import { request, ResponseError } from "$app/utils/request";
import { isPasskeySupported } from "$app/utils/webauthn";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

const MAX_PASSKEYS = 10;
const MAX_NICKNAME_LENGTH = 100;
const GENERIC_ERROR = "Sorry, something went wrong. Please try again.";

export type { Passkey };

const formatPasskeyDate = (value: string) => formatDate(parseISO(value), { dateStyle: "medium" });

export const PasskeysSection = ({ passkeys: initialPasskeys }: { passkeys: Passkey[] }) => {
  const [passkeys, setPasskeys] = React.useState(initialPasskeys);
  const [adding, setAdding] = React.useState(false);
  const [editingId, setEditingId] = React.useState<string | null>(null);
  const [editingNickname, setEditingNickname] = React.useState("");
  const [savingRename, setSavingRename] = React.useState(false);
  const [pendingDeletion, setPendingDeletion] = React.useState<Passkey | null>(null);
  const [deleting, setDeleting] = React.useState(false);
  const supported = isPasskeySupported();
  const reachedLimit = passkeys.length >= MAX_PASSKEYS;

  const handleAdd = asyncVoid(async () => {
    setAdding(true);
    try {
      const added = await registerPasskey();
      setPasskeys((current) => [...current, added]);
      showAlert("Passkey added.", "success");
    } catch (e) {
      if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) return;
      showAlert(e instanceof ResponseError ? e.message : PASSKEY_ADD_ERROR, "error");
    } finally {
      setAdding(false);
    }
  });

  const handleRename = asyncVoid(async (passkey: Passkey) => {
    const nickname = editingNickname.trim();
    if (!nickname || nickname === passkey.nickname) {
      setEditingId(null);
      return;
    }

    setSavingRename(true);
    try {
      const response = await request({
        url: Routes.settings_passkey_path(passkey.id),
        method: "PATCH",
        accept: "json",
        data: { nickname },
      });
      const result = typia.assert<{ success: boolean; passkey?: Passkey; error_message?: string }>(
        await response.json(),
      );
      if (!response.ok || !result.success || !result.passkey) {
        throw new ResponseError(result.error_message ?? GENERIC_ERROR);
      }

      const updated = result.passkey;
      setPasskeys((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setEditingId(null);
    } catch (e) {
      showAlert(e instanceof ResponseError ? e.message : GENERIC_ERROR, "error");
    } finally {
      setSavingRename(false);
    }
  });

  const handleConfirmDelete = asyncVoid(async () => {
    if (!pendingDeletion) return;

    setDeleting(true);
    try {
      const response = await request({
        url: Routes.settings_passkey_path(pendingDeletion.id),
        method: "DELETE",
        accept: "json",
      });
      const result = typia.assert<{ success: boolean; error_message?: string }>(await response.json());
      if (!response.ok || !result.success) {
        throw new ResponseError(result.error_message ?? GENERIC_ERROR);
      }

      setPasskeys((current) => current.filter((item) => item.id !== pendingDeletion.id));
      setPendingDeletion(null);
      showAlert("Passkey removed.", "success");
    } catch (e) {
      showAlert(e instanceof ResponseError ? e.message : GENERIC_ERROR, "error");
    } finally {
      setDeleting(false);
    }
  });

  return (
    <>
      {passkeys.length === 0 ? (
        <Alert variant="info">
          Passkeys are an easier, more secure alternative to passwords. Sign in with your fingerprint, face, or screen
          lock.
        </Alert>
      ) : (
        <Rows role="list">
          {passkeys.map((passkey) =>
            editingId === passkey.id ? (
              <Row key={passkey.id} role="listitem">
                <RowContent>
                  <Input
                    className="flex-1"
                    value={editingNickname}
                    onChange={(e) => setEditingNickname(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        if (editingNickname.trim()) handleRename(passkey);
                      } else if (e.key === "Escape") {
                        setEditingId(null);
                      }
                    }}
                    aria-label="Passkey name"
                    maxLength={MAX_NICKNAME_LENGTH}
                    autoFocus
                    disabled={savingRename}
                  />
                </RowContent>
                <RowActions>
                  <Button
                    color="accent"
                    onClick={() => handleRename(passkey)}
                    disabled={savingRename || !editingNickname.trim()}
                  >
                    {savingRename ? "Saving..." : "Save"}
                  </Button>
                  <Button onClick={() => setEditingId(null)} disabled={savingRename}>
                    Cancel
                  </Button>
                </RowActions>
              </Row>
            ) : (
              <Row key={passkey.id} role="listitem">
                <RowContent>
                  <div className="grid gap-1">
                    <div className="font-bold">{passkey.nickname}</div>
                    <FieldsetDescription>
                      Added {formatPasskeyDate(passkey.created_at)} ·{" "}
                      {passkey.last_used_at ? `last used ${formatPasskeyDate(passkey.last_used_at)}` : "never used"}
                    </FieldsetDescription>
                  </div>
                </RowContent>
                <RowActions>
                  <Button
                    onClick={() => {
                      setEditingId(passkey.id);
                      setEditingNickname(passkey.nickname);
                    }}
                  >
                    Rename
                  </Button>
                  <Button color="danger" outline onClick={() => setPendingDeletion(passkey)}>
                    Remove
                  </Button>
                </RowActions>
              </Row>
            ),
          )}
        </Rows>
      )}

      {supported ? (
        reachedLimit ? (
          <FieldsetDescription>You've reached the maximum of {MAX_PASSKEYS} passkeys.</FieldsetDescription>
        ) : (
          <div>
            <Button color="accent" onClick={handleAdd} disabled={adding}>
              {adding ? "Waiting for passkey..." : "Add a passkey"}
            </Button>
          </div>
        )
      ) : (
        <FieldsetDescription>This browser doesn't support passkeys.</FieldsetDescription>
      )}

      {pendingDeletion ? (
        <Modal
          open
          onClose={() => (deleting ? null : setPendingDeletion(null))}
          title="Remove passkey"
          footer={
            <>
              <Button onClick={() => setPendingDeletion(null)} disabled={deleting}>
                Cancel
              </Button>
              <Button color="danger" onClick={handleConfirmDelete} disabled={deleting}>
                {deleting ? "Removing..." : "Remove"}
              </Button>
            </>
          }
        >
          <p>
            Remove <strong>{pendingDeletion.nickname}</strong>? You won't be able to use it to sign in anymore.
          </p>
        </Modal>
      ) : null}
    </>
  );
};
