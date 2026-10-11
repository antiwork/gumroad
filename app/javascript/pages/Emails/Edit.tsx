import { usePage } from "@inertiajs/react";
import React from "react";

import { Installment, InstallmentFormContext } from "$app/data/installments";
import { cast } from "$app/utils/cast";

import { EmailForm } from "$app/components/EmailsPage/EmailForm";

export default function EmailsEdit() {
  const { installment, context } = cast<{ installment: Installment; context: InstallmentFormContext }>(usePage().props);

  return <EmailForm context={context} installment={installment} />;
}
