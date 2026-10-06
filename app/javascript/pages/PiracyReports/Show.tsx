import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";

type ReportState = "requested" | "screening" | "awaiting_signature" | "signed" | "declined";

type PiracyReportsShowProps = {
  report: {
    id: string;
    state: ReportState;
    url: string;
    created_at: string;
    notice_text: string | null;
    notice_digest: string | null;
    signed_at: string | null;
    signed_by_name: string | null;
  };
  product: { name: string; url: string };
};

export default function PiracyReportsShow() {
  const { report, product } = usePage<PiracyReportsShowProps>().props;

  const form = useForm({ signed_by_name: "" });
  const canSign = report.state === "awaiting_signature" && report.notice_text !== null;

  const submit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    form.post(Routes.sign_piracy_report_path(report.id));
  };

  return (
    <>
      <PageHeader title="Report piracy">
        <p>
          <strong>{product.name}</strong> — {report.url}
        </p>
      </PageHeader>
      <div className="grid gap-4 p-4 md:p-8">
        {report.state === "requested" || report.state === "screening" ? (
          <Alert variant="info">
            We are reviewing the page. You will get an email when the notice is ready to sign.
          </Alert>
        ) : null}
        {report.state === "declined" ? (
          <Alert variant="warning">
            We could not confirm that this page offers a copy of your work, so we have not sent anything. If you have
            more evidence, reply to your support thread.
          </Alert>
        ) : null}
        {report.state === "signed" ? (
          <Alert variant="success">
            Signed by {report.signed_by_name}. We will send the notice and email you when the site responds.
          </Alert>
        ) : null}
        {report.notice_text === null ? null : (
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor="notice">The notice</Label>
            </FieldsetTitle>
            <FieldsetDescription>This is exactly what we send. It is fixed once you sign it.</FieldsetDescription>
            <pre id="notice" className="max-h-96 overflow-auto rounded border border-border p-4 whitespace-pre-wrap">
              {report.notice_text}
            </pre>
          </Fieldset>
        )}
        {canSign ? (
          <form onSubmit={submit} className="grid gap-4">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="signed_by_name">Sign with your full legal name</Label>
              </FieldsetTitle>
              <FieldsetDescription>
                Your signature confirms the statements in the notice are accurate and that you authorize Gumroad to send
                it on your behalf.
              </FieldsetDescription>
              <Input
                id="signed_by_name"
                value={form.data.signed_by_name}
                onChange={(event) => form.setData("signed_by_name", event.target.value)}
                required
              />
              {form.errors.signed_by_name ? <Alert variant="danger">{form.errors.signed_by_name}</Alert> : null}
            </Fieldset>
            <div>
              <Button type="submit" color="primary" disabled={form.processing}>
                {form.processing ? "Signing..." : "Sign and send"}
              </Button>
            </div>
          </form>
        ) : null}
      </div>
    </>
  );
}
