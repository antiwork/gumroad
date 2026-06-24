import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { USER_FIELDS } from "../responseFieldDefinitions";

export const GetUser = () => (
  <ApiEndpoint method="get" path="/user" description="Retrieve the user's data.">
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "user", type: "object", description: "The user object", children: USER_FIELDS },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad user</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "user": {
    "bio": "a sailor, a tailor",
    "name": "John Smith",
    "twitter_handle": null,
    "user_id": "G_-mnBf9b1j9A7a4ub4nFQ==",
    "email": "johnsmith@gumroad.com", # available with the 'view_sales' scope
    "url": "https://gumroad.com/sailorjohn", # only if username is set
    "profile_picture_url": "https://assets.gumroad.com/user/abc/avatar"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

const ProfileCustomHtmlDocumentation = () => (
  <div id="profile-custom-html" className="grid gap-4">
    <h4>Custom HTML profile page</h4>
    <p>
      You can give your public profile at <code>/:username</code> a custom HTML landing page, stored in the profile's{" "}
      <code>custom_html</code> field. While it's set, visitors see it instead of the default profile sections.
      Authenticate with a Bearer token that has the <code>edit_profile</code> scope (the <code>view_profile</code> scope
      is enough to read it). This is the same sanitized, sandboxed rendering as a{" "}
      <a href="#custom-html">product landing page</a>, scoped to your profile.
    </p>
    <ul>
      <li>
        <code>GET /v2/user/custom_html</code> returns the current <code>custom_html</code>, a{" "}
        <code>has_landing_page</code> flag, and your public <code>profile_url</code>.
      </li>
      <li>
        <code>PUT /v2/user/custom_html</code> sets it; send <code>null</code> or an empty string to clear it and fall
        back to the default profile.
      </li>
      <li>
        <code>POST /v2/user/preview_custom_html</code> returns the sanitized HTML and a sanitization report without
        saving — use it to iterate before you publish.
      </li>
      <li>
        Both <code>PUT</code> and preview return a <code>sanitization_report</code> listing what was stripped.
      </li>
      <li>
        A successful <code>PUT</code> also returns <code>previous_custom_html</code> (the prior value, for one-step
        rollback) and your <code>profile_url</code>.
      </li>
      <li>Only the latest version is stored — there's no history, so keep your source under version control.</li>
      <li>The HTML is capped at 500,000 characters.</li>
      <li>
        Rate limits per token: 30 <code>PUT</code>s/min, 60 previews/min.
      </li>
    </ul>
    <p>
      Your HTML is sanitized — disallowed tags and attributes are stripped — then served inside a sandboxed iframe (
      <code>sandbox="allow-scripts allow-forms"</code>). It can run inline JavaScript, load scripts from the Tailwind,
      jsDelivr, and unpkg CDNs, and load fonts from Google Fonts and Bunny Fonts. It can't read your Gumroad cookies or
      session (it runs on an opaque origin), touch or navigate the parent page, or make <code>fetch</code>/
      <code>XHR</code>/WebSocket requests (<code>connect-src 'none'</code>). Images and media may only load from
      Gumroad.
    </p>
    <h5>Live values</h5>
    <p>Mark elements with data attributes that Gumroad fills in server-side so the page always shows current values:</p>
    <ul>
      <li>
        <code>data-gumroad-field="name"</code> — replaced with your profile name (HTML-escaped).
      </li>
      <li>
        <code>data-gumroad-field="bio"</code> — replaced with your profile bio (HTML-escaped).
      </li>
    </ul>
    <p>
      Unlike a product landing page, a profile has no native checkout, so there are no buy buttons —{" "}
      <code>data-gumroad-action="buy"</code> and the <code>gumroad:checkout</code> bridge don't apply. Link to your
      products or profile sections instead.
    </p>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user/custom_html \\
  -X PUT \\
  -H "Authorization: Bearer <user_api_token>" \\
  -H "Content-Type: application/json" \\
  -d '{"custom_html":"<main><h1 data-gumroad-field=\\"name\\"></h1></main>"}'`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad user page preview ./landing.html
gumroad user page publish ./landing.html`}
    </CodeSnippet>
  </div>
);

export const GetUserCustomHtml = () => (
  <ApiEndpoint method="get" path="/user/custom_html" description="Retrieve your profile's custom HTML landing page.">
    <ProfileCustomHtmlDocumentation />
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "custom_html", type: "string", description: "The published profile HTML, or null if none is set" },
        { name: "has_landing_page", type: "boolean", description: "Whether a custom profile page is currently set" },
        { name: "profile_url", type: "string", description: "Your public profile URL" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user/custom_html \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad user page url</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "custom_html": "<main><h1>Moonwalk Records</h1></main>",
  "has_landing_page": true,
  "profile_url": "https://sailorjohn.gumroad.com"
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateUserCustomHtml = () => (
  <ApiEndpoint
    method="put"
    path="/user/custom_html"
    description="Publish or clear your profile's custom HTML landing page."
  >
    <ApiParameters>
      <ApiParameter
        name="custom_html"
        description="(required) the profile landing page HTML; null or an empty string clears it"
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "custom_html", type: "string", description: "The sanitized HTML that was stored, or null if cleared" },
        {
          name: "previous_custom_html",
          type: "string",
          description: "The value before this write, for one-step rollback (null if there was none)",
        },
        { name: "profile_url", type: "string", description: "Your public profile URL" },
        {
          name: "sanitization_report",
          type: "object",
          description: "What the sanitizer removed (removed_tags, removed_attributes, total_removed, truncated)",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user/custom_html \\
  -X PUT \\
  -H "Authorization: Bearer ACCESS_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"custom_html":"<main><h1>My profile</h1></main>"}'`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad user page publish ./landing.html</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "custom_html": "<main><h1>My profile</h1></main>",
  "previous_custom_html": null,
  "profile_url": "https://sailorjohn.gumroad.com",
  "sanitization_report": {
    "removed_tags": [],
    "removed_attributes": [],
    "total_removed": 0,
    "truncated": false
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const PreviewUserCustomHtml = () => (
  <ApiEndpoint
    method="post"
    path="/user/preview_custom_html"
    description="Sanitize profile HTML and return the result without saving."
  >
    <ApiParameters>
      <ApiParameter name="custom_html" description="(required) the HTML to sanitize" />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "custom_html", type: "string", description: "The sanitized HTML (not saved)" },
        {
          name: "sanitization_report",
          type: "object",
          description: "What the sanitizer removed (removed_tags, removed_attributes, total_removed, truncated)",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/user/preview_custom_html \\
  -X POST \\
  -H "Authorization: Bearer ACCESS_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"custom_html":"<main><h1>My profile</h1></main>"}'`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad user page preview ./landing.html</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "custom_html": "<main><h1>My profile</h1></main>",
  "sanitization_report": {
    "removed_tags": [],
    "removed_attributes": [],
    "total_removed": 0,
    "truncated": false
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
