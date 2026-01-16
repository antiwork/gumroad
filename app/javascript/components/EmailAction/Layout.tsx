import * as React from "react";

import { useDomains } from "$app/components/DomainSettings";
import { Card, CardContent } from "$app/components/ui/Card";

export const Layout = ({ heading, children }: { heading: string; children: React.ReactNode }) => {
  const { rootDomain } = useDomains();

  return (
    <>
      <Card>
        <CardContent asChild>
          <header>
            <h2 className="grow">{heading}</h2>
          </header>
        </CardContent>
        <CardContent asChild>
          <p>{children}</p>
        </CardContent>
      </Card>
      <footer
        style={{
          textAlign: "center",
          padding: "var(--spacer-4)",
        }}
      >
        Powered by&ensp;
        <a href={Routes.root_url({ host: rootDomain })} className="logo-full" aria-label="Gumroad" />
      </footer>
    </>
  );
};
