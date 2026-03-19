import * as React from "react";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";

const copyToClipboard = (text: string) => {
  void navigator.clipboard.writeText(text).then(
    () => showAlert("Copied to clipboard.", "success"),
    () => showAlert("Failed to copy.", "error"),
  );
};

const handleDownload = (codes: string[]) => {
  const blob = new Blob([codes.join("\n")], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "gumroad-recovery-codes.txt";
  a.click();
  URL.revokeObjectURL(url);
};

export const RecoveryCodes = ({ codes, onDone }: { codes: string[]; onDone: () => void }) => (
  <div className="grid gap-4">
    <Alert variant="warning">Save these codes. You'll need them if you lose your authenticator app.</Alert>
    <div className="grid w-fit gap-4">
      <div className="grid grid-cols-2 gap-x-8 gap-y-2 rounded border border-border p-4 font-mono text-sm">
        {codes.map((code) => (
          <div key={code}>{code}</div>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-2">
        <Button onClick={() => copyToClipboard(codes.join("\n"))}>Copy all</Button>
        <Button onClick={() => handleDownload(codes)}>Download</Button>
      </div>
    </div>
    <div>
      <Button color="accent" onClick={onDone}>
        Done
      </Button>
    </div>
  </div>
);
