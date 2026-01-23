import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  invoice_url: string;
};

export default function Confirm() {
  const { invoice_url } = cast<Props>(usePage().props);

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
            <form action={invoice_url} className="flex flex-col gap-4" method="get">
              <input type="text" name="email" placeholder="Email address" className="grow" />
              <Button type="submit" color="accent">
                Confirm email
              </Button>
            </form>
          </CardContent>
        </main>
      </Card>
    </div>
  );
}

Confirm.disableLayout = true;
