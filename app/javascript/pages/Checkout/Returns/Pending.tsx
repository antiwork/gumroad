import * as React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export default function Pending() {
  return (
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          <h2 className="grow">Your payment is being processed</h2>
        </header>
      </CardContent>
      <CardContent>
        Check your email for your receipt — it will arrive once the payment completes. Please do not pay again.
      </CardContent>
    </Card>
  );
}

Pending.publicLayout = true;
