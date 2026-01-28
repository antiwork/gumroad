import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  invoice_url: string;
  flash?: {
    message: string;
    status: "danger" | "warning" | "success";
  };
};

export default function Confirm({ invoice_url }: Props) {
  const { flash } = usePage<Props>().props;
  const form = useForm({
    email: "",
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.get(invoice_url);
  };

  return (
    <>
      <Card asChild>
        <main className="single-page-form horizontal-form mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
          <CardContent asChild>
            <header className="text-center">
              <h2 className="grow">Generate invoice</h2>
            </header>
          </CardContent>
          <CardContent asChild>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              {flash?.message ? (
                <Alert variant={flash.status === "success" ? "success" : "danger"}>{flash.message}</Alert>
              ) : null}
              <input
                type="text"
                name="email"
                placeholder="Email address"
                className="grow"
                value={form.data.email}
                onChange={(e) => form.setData("email", e.target.value)}
              />
              <Button type="submit" color="accent" disabled={form.processing}>
                Confirm email
              </Button>
            </form>
          </CardContent>
        </main>
      </Card>
      <PoweredByFooter />
    </>
  );
}

Confirm.disableLayout = true;
