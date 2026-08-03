import { usePage } from "@inertiajs/react";
import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  seller_response_due_at_formatted: string | null;
  purchase_for_dispute_evidence_id: string;
};

export default function Success() {
  const { seller_response_due_at_formatted, purchase_for_dispute_evidence_id } = usePage<Props>().props;

  return (
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          Dispute evidence
          <h2 className="grow">Submit additional information</h2>
        </header>
      </CardContent>
      <CardContent>
        <p>Thank you! We've saved your response.</p>
        <p>
          {seller_response_due_at_formatted !== null
            ? `We send it to our payment processor at the deadline, ${seller_response_due_at_formatted}. Until then you can come back and add files or revise what you wrote.`
            : "We send it to our payment processor at the deadline. Until then you can come back and add files or revise what you wrote."}
        </p>
        <NavigationButton href={Routes.purchase_dispute_evidence_path(purchase_for_dispute_evidence_id)}>
          Add to your response
        </NavigationButton>
      </CardContent>
    </Card>
  );
}

Success.publicLayout = true;
