import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { AlertPayload } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { useFlashMessage } from "$app/components/useFlashMessage";

type PageProps = {
  message: string;
  field_name: string;
  error_message: string;
  encrypted_payload: string;
  flash?: AlertPayload | null;
};

function NewPage() {
  const { props } = usePage();
  const pageProps = cast<PageProps>(props);
  useFlashMessage(pageProps.flash);

  const uid = React.useId();

  const form = useForm({
    confirmation_text: "",
    encrypted_payload: pageProps.encrypted_payload,
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    form.post(`${Routes.secure_url_redirect_path()}${window.location.search}`, { preserveScroll: true });
  };

  return (
    <div className="flex h-full flex-col">
      <Card className="single-page-form horizontal-form">
        <CardContent asChild>
          <header>
            <h2 className="grow">Confirm access</h2>
            <p>{pageProps.message}</p>
          </header>
        </CardContent>
        <CardContent className="mini-rule legacy-only"></CardContent>
        <CardContent asChild>
          <form onSubmit={handleSubmit}>
            <label htmlFor={`${uid}-confirmation-text`} className="form-label grow">
              {pageProps.field_name}
            </label>
            <input
              id={`${uid}-confirmation-text`}
              type="text"
              placeholder={pageProps.field_name}
              value={form.data.confirmation_text}
              onChange={(e) => form.setData("confirmation_text", e.target.value)}
              autoFocus
              disabled={form.processing}
            />
            <Button color="primary" type="submit" disabled={form.processing}>
              {form.processing ? "Processing..." : "Continue"}
            </Button>
          </form>
        </CardContent>
      </Card>
      <PoweredByFooter className="mt-auto lg:py-4" />
    </div>
  );
}

export default NewPage;
