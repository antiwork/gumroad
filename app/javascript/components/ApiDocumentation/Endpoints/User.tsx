import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";

export const GetUser = () => (
  <ApiEndpoint method="get" path="/user" description="Retrieve the user's data.">
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "user": {
    "bio": "a sailor, a tailor",
    "name": "John Smith",
    "twitter_handle": null,
    "user_id": "G_-mnBf9b1j9A7a4ub4nFQ==",
    "email": "johnsmith@gumroad.com", # available with the 'view_sales' scope
    "url": "https://gumroad.com/sailorjohn" # only if username is set
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
