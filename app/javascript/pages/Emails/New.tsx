import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { Installment, InstallmentFormContext } from "$app/data/installments";

import { EmailForm } from "$app/components/EmailsPage/EmailForm";

export default function EmailsNew() {
  const { context, installment, single_customer_recipient } = typia.assert<{
    context: InstallmentFormContext;
    installment: Installment | null;
    single_customer_recipient: { purchase_id: string; email: string } | null;
  }>(usePage().props);

  return <EmailForm context={context} installment={installment} singleCustomerRecipient={single_customer_recipient} />;
}
