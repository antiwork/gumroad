import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export const ApiResource = ({ name, id, children }: { name: string; id: string; children: React.ReactNode }) => (
  <Card id={id}>
    <CardContent>
      <h2 className="grow">{name}</h2>
    </CardContent>
    <CardContent details>{children}</CardContent>
  </Card>
);
