import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";

type PiracyReportsNewProps = {
  product: { id: string; name: string; url: string };
  eligibility_errors: string[];
  reports_this_month: number;
  monthly_limit: number;
};

export default function PiracyReportsNew() {
  const { product, eligibility_errors, reports_this_month, monthly_limit } = usePage<PiracyReportsNewProps>().props;

  const form = useForm({ product_id: product.id, url: "" });
  const limitReached = reports_this_month >= monthly_limit;
  const blocked = eligibility_errors.length > 0 || limitReached;

  const submit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    form.post(Routes.piracy_reports_path());
  };

  return (
    <form onSubmit={submit}>
      <PageHeader
        title="Report piracy"
        showTitleOnMobile
        actions={
          <Button asChild>
            <Link href={Routes.piracy_reports_path()}>All piracy reports</Link>
          </Button>
        }
      >
        <p>
          Tell us where <strong>{product.name}</strong> is being offered without your permission. We check the page,
          then send you the takedown notice to sign before anything goes out.
        </p>
      </PageHeader>
      <div className="grid gap-4 p-4 md:p-8">
        {eligibility_errors.length > 0 ? (
          <Alert variant="warning">
            <div>
              <strong>You cannot report piracy for this product yet:</strong>
              <ul className="list-disc pl-4">
                {eligibility_errors.map((error) => (
                  <li key={error}>{error}</li>
                ))}
              </ul>
            </div>
          </Alert>
        ) : null}
        {limitReached ? (
          <Alert variant="warning">You have used all {monthly_limit} reports for this month.</Alert>
        ) : null}
        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor="url">Link to the page offering your work</Label>
          </FieldsetTitle>
          <FieldsetDescription>
            One page per report. It has to be on another site, and it has to be a page you can point us to directly.
          </FieldsetDescription>
          <Input
            id="url"
            type="url"
            inputMode="url"
            placeholder="https://"
            value={form.data.url}
            onChange={(event) => form.setData("url", event.target.value)}
            disabled={blocked}
            required
          />
          {form.errors.url ? <Alert variant="danger">{form.errors.url}</Alert> : null}
        </Fieldset>
        <div>
          <Button type="submit" color="primary" disabled={blocked || form.processing}>
            {form.processing ? "Submitting..." : "Submit report"}
          </Button>
        </div>
      </div>
    </form>
  );
}
