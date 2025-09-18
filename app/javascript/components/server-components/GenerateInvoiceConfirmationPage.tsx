import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";

type EmailConfirmationProps = {
  invoice_url: string;
};

const GenerateInvoiceConfirmationPage = ({ invoice_url }: EmailConfirmationProps) => (
  <main className="stack single-page-form horizontal-form">
    <EmailConfirmation invoice_url={invoice_url} />
  </main>
);

const EmailConfirmation = ({ invoice_url }: EmailConfirmationProps) => (
  <>
    <header>
      <h2>Generate invoice</h2>
    </header>
    <form action={invoice_url} className="paragraphs" method="get">
      <input type="text" name="email" placeholder="Email address" />
      <Button type="submit" color="accent">
        Confirm email
      </Button>
    </form>
  </>
);

export default register({ component: GenerateInvoiceConfirmationPage, propParser: createCast() });
