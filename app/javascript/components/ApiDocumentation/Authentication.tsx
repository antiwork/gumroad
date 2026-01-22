import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

export const Authentication = () => (
  <Card id="api-authentication">
    <CardContent>
      <h2 className="grow">Authentication</h2>
    </CardContent>
    <CardContent>
      <p className="grow">
        On the application page, click{" "}
        <a href="#" data-helper-prompt="How do I generate an access token?">
          Generate access token
        </a>{" "}
        to get the token you will use with the API.
      </p>
    </CardContent>
  </Card>
);
