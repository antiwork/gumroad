import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

const ERROR_CODES = [
  { code: "200 OK", description: "everything worked as expected." },
  { code: "400 Bad Request", description: "you probably missed a required parameter." },
  { code: "401 Unauthorized", description: "you did not provide a valid access token." },
  { code: "402 Request Failed", description: "the parameters were valid but request failed." },
  { code: "404 Not Found", description: "the requested item doesn't exist." },
  { code: "500, 502, 503, 504 Server Error", description: "something else went wrong on our end." },
];

export const Errors = () => (
  <div className="stack" id="api-errors">
    <div>
      <h2>API Errors</h2>
    </div>
    <div>
      <div className="flex flex-col gap-4">
        <p>
          Gumroad uses HTTP status codes to indicate the status of a request. Here's a run down on likely response
          codes.
        </p>
        <p>
          {ERROR_CODES.map((code, index) => (
            <React.Fragment key={index}>
              <strong>{code.code}</strong> {code.description}
              <br />
            </React.Fragment>
          ))}
        </p>
        <p>
          To help you further, we provide a JSON object that goes more in-depth about the problem that led to the failed
          request. Errors responses from the api will follow the following format.
        </p>
        <CodeSnippet>
          {JSON.stringify(
            {
              success: false,
              message: "The product could not be found.",
            },
            null,
            2,
          )}
        </CodeSnippet>
        <p></p>
        <p>When present, the message will describe the particular problem and suggestions on what went wrong.</p>
      </div>
    </div>
  </div>
);
