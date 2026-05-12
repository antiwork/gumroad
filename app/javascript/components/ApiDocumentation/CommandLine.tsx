import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";
import CodeSnippet from "$app/components/ui/CodeSnippet";

export const CommandLine = () => (
  <Card id="api-cli">
    <CardContent>
      <h2 className="grow">Command line</h2>
    </CardContent>
    <CardContent>
      <div className="flex grow flex-col gap-4">
        <p>
          Prefer a terminal? The{" "}
          <a href="https://github.com/antiwork/gumroad-cli" target="_blank" rel="noopener noreferrer">
            Gumroad CLI
          </a>{" "}
          wraps every endpoint below and is built for humans and AI agents alike.
        </p>
        <CodeSnippet caption="Install with Homebrew">brew install antiwork/cli/gumroad</CodeSnippet>
        <CodeSnippet caption="Or run the install script">
          curl -fsSL https://gumroad.com/install-cli.sh | bash
        </CodeSnippet>
        <p>
          Each endpoint below shows the matching <code>gumroad</code> invocation next to its cURL example. Run{" "}
          <code>gumroad &lt;command&gt; --help</code> for the full list of flags.
        </p>
      </div>
    </CardContent>
  </Card>
);
