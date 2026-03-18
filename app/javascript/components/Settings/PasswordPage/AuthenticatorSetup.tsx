import { router } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Skeleton } from "$app/components/Skeleton";
import { Alert } from "$app/components/ui/Alert";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

type Step = "setup" | "recovery";

type SetupData = {
  secret: string;
  qr_svg: string;
};

const copyToClipboard = (text: string) => {
  void navigator.clipboard.writeText(text).then(
    () => showAlert("Copied to clipboard.", "success"),
    () => showAlert("Failed to copy.", "error"),
  );
};

export const AuthenticatorSetup = ({ onCancel }: { onCancel: () => void }) => {
  const [step, setStep] = React.useState<Step>("setup");
  const [setupData, setSetupData] = React.useState<SetupData | null>(null);
  const [code, setCode] = React.useState("");
  const [error, setError] = React.useState<string | null>(null);
  const [recoveryCodes, setRecoveryCodes] = React.useState<string[]>([]);
  const [verifying, setVerifying] = React.useState(false);
  const [showSecret, setShowSecret] = React.useState(false);
  const uid = React.useId();

  const loading = setupData === null && error === null;

  React.useEffect(() => {
    const controller = new AbortController();
    const startSetup = async () => {
      try {
        const response = await request({
          url: Routes.settings_totp_path(),
          method: "POST",
          accept: "json",
          abortSignal: controller.signal,
        });
        const json = cast<{ success: boolean; secret: string; qr_svg: string }>(await response.json());
        if (json.success) {
          setSetupData({ secret: json.secret, qr_svg: json.qr_svg });
        } else {
          setError("Something went wrong. Please try again.");
        }
      } catch {
        if (controller.signal.aborted) return;
        setError("Something went wrong. Please try again.");
      }
    };
    void startSetup();
    return () => controller.abort();
  }, []);

  const handleVerify = async () => {
    setError(null);
    setVerifying(true);
    try {
      const response = await request({
        url: Routes.confirm_settings_totp_path(),
        method: "POST",
        accept: "json",
        data: { code },
      });
      const json = cast<{ success: boolean; recovery_codes?: string[]; error_message?: string }>(await response.json());
      if (json.success && json.recovery_codes) {
        setRecoveryCodes(json.recovery_codes);
        setStep("recovery");
      } else {
        setError(json.error_message ?? "Invalid code. Please try again.");
      }
    } catch {
      setError("Something went wrong. Please try again.");
    } finally {
      setVerifying(false);
    }
  };

  const handleDownload = () => {
    const blob = new Blob([recoveryCodes.join("\n")], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "gumroad-recovery-codes.txt";
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleDone = () => {
    onCancel();
    router.reload();
  };

  if (error && !setupData) {
    return (
      <div className="grid gap-4">
        <Alert variant="danger">{error}</Alert>
        <div>
          <Button onClick={onCancel}>Cancel</Button>
        </div>
      </div>
    );
  }

  if (step === "setup") {
    return (
      <div className="grid gap-4">
        <div className="aspect-square w-full max-w-48 shrink-0 justify-self-start overflow-hidden rounded border border-border bg-white">
          {setupData ? (
            <div
              className="h-full w-full [&_svg]:block [&_svg]:h-full [&_svg]:w-full"
              dangerouslySetInnerHTML={{ __html: setupData.qr_svg }}
            />
          ) : (
            <Skeleton className="h-full w-full rounded-none" />
          )}
        </div>
        <p className="text-muted">
          Scan this QR code with your authenticator app. Can't scan? Use the{" "}
          <button
            type="button"
            className="cursor-pointer underline all-unset disabled:cursor-default disabled:opacity-50"
            onClick={() => setShowSecret(true)}
            disabled={!setupData}
          >
            setup key
          </button>{" "}
          instead.
        </p>
        <Modal open={showSecret ? setupData !== null : false} title="Setup key" onClose={() => setShowSecret(false)}>
          <div className="grid gap-4">
            <code className="rounded border border-border bg-background p-3 font-mono text-sm break-all">
              {setupData?.secret}
            </code>
            <Button onClick={() => setupData?.secret && copyToClipboard(setupData.secret)}>Copy</Button>
          </div>
        </Modal>
        {error ? <Alert variant="danger">{error}</Alert> : null}
        <div className="grid gap-2">
          <Label htmlFor={`${uid}-code`}>Enter the code from your authenticator app</Label>
          <Input
            id={`${uid}-code`}
            type="text"
            inputMode="numeric"
            pattern="[0-9]*"
            maxLength={6}
            placeholder="XXXXXX"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            autoFocus
            autoComplete="one-time-code"
          />
        </div>
        <div className="flex gap-2">
          <Button color="accent" onClick={() => void handleVerify()} disabled={loading || code.length < 6 || verifying}>
            {verifying ? "Verifying..." : "Verify"}
          </Button>
          <Button onClick={onCancel}>Cancel</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="grid gap-4">
      <Alert variant="warning">Save these codes. You'll need them if you lose your authenticator app.</Alert>
      <div className="grid w-fit gap-4">
        <div className="grid grid-cols-2 gap-x-8 gap-y-2 rounded border border-border p-4 font-mono text-sm">
          {recoveryCodes.map((recoveryCode) => (
            <div key={recoveryCode}>{recoveryCode}</div>
          ))}
        </div>
        <div className="grid grid-cols-2 gap-2">
          <Button onClick={() => copyToClipboard(recoveryCodes.join("\n"))}>Copy all</Button>
          <Button onClick={handleDownload}>Download</Button>
        </div>
      </div>
      <div>
        <Button color="accent" onClick={handleDone}>
          Done
        </Button>
      </div>
    </div>
  );
};
