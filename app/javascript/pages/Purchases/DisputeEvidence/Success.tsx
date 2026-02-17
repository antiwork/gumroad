import * as React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export default function Success() {
  return (
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          Dispute evidence
          <h2 className="grow">Submit additional information</h2>
        </header>
      </CardContent>
      <CardContent>Thank you!</CardContent>
    </Card>
  );
}

Success.publicLayout = true;
