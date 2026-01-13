import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

type EmailConfirmationProps = {
  invoice_url: string;
};

const GenerateInvoiceConfirmationPage = ({ invoice_url }: EmailConfirmationProps) => (
  <div>
    <Card asChild>
      <main className="single-page-form horizontal-form mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
        <EmailConfirmation invoice_url={invoice_url} />
      </main>
    </Card>
  </div>
);

const EmailConfirmation = ({ invoice_url }: EmailConfirmationProps) => (
  <>
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
  </>
);

export default register({ component: GenerateInvoiceConfirmationPage, propParser: createCast() });
