import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

type PageProps = {
  invoice_url: string;
};

export default function ConfirmGenerateInvoicePage() {
  const props = cast<PageProps>(usePage().props);

  const form = useForm({
    email: "",
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.get(props.invoice_url);
  };

  return (
    <div>
      <Card asChild>
        <main className="single-page-form horizontal-form mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
          <CardContent asChild>
            <header className="text-center">
              <h2 className="grow">Generate invoice</h2>
            </header>
          </CardContent>
          <CardContent asChild>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <input
                type="text"
                name="email"
                placeholder="Email address"
                className="grow"
                value={form.data.email}
                onChange={(e) => form.setData("email", e.target.value)}
                required
              />
              <Button type="submit" color="accent" disabled={form.processing}>
                {form.processing ? "Confirming..." : "Confirm email"}
              </Button>
            </form>
          </CardContent>
        </main>
      </Card>
    </div>
  );
}
