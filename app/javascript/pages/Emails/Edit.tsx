import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { Installment, InstallmentFormContext } from "$app/data/installments";

import { EmailForm } from "$app/components/EmailsPage/EmailForm";

export default function EmailsEdit() {
  const { installment, context } = typia.assert<{ installment: Installment; context: InstallmentFormContext }>(usePage().props);

  return <EmailForm context={context} installment={installment} />;
}
