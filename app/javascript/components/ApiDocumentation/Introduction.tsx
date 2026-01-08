import { Link } from "@inertiajs/react";
import React from "react";

export const Introduction = () => (
  <div className="stack" id="api-intro">
    <div>
      <p>
        The Gumroad OAuth API is based around REST. We return JSON for every request, including{" "}
        <a href="#api-errors">errors</a>.
      </p>
    </div>
    <div>
      <div className="flex flex-col gap-4">
        <p>
          To start using the API, you'll need to{" "}
          <Link href="/settings/advanced#application-form">register your OAuth application</Link>. Note: The{" "}
          <a href="#licenses">Verify License API endpoint</a> does not require an OAuth application.
        </p>
        <p>After creating an application, you'll be given a unique application id and application secret.</p>
      </div>
    </div>
  </div>
);
