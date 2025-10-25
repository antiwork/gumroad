import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Stack } from "$app/components/ui/Stack";
import { classNames } from "$app/utils/classNames";

type EmailConfirmationProps = {
  invoice_url: string;
  classname?: string | undefined;
  grow?: boolean | undefined;
  header?: boolean | undefined;
};

const GenerateInvoiceConfirmationPage = ({ invoice_url }: EmailConfirmationProps) => (
  <Stack as = "main" className="single-page-form horizontal-form">
    <EmailConfirmation invoice_url={invoice_url} classname="flex flex-wrap items-center p-4 gap-4 justify-between not-first:border-t not-first:border-border" grow header />
  </Stack>
);

const EmailConfirmation = ({ invoice_url ,classname,grow, header}: EmailConfirmationProps) => (
  <>
    <header className={classNames(classname,header? "text-center":"")}>
      <h2 className={grow? "grow" : ""}>Generate invoice</h2>
    </header>
    <form action={invoice_url} className={classNames("paragraphs",classname)} method="get">
      <input className={grow? "grow" : ""} type="text" name="email" placeholder="Email address" />
      <Button type="submit" color="accent">
        Confirm email
      </Button>
    </form>
  </>
);

export default register({ component: GenerateInvoiceConfirmationPage, propParser: createCast() });
