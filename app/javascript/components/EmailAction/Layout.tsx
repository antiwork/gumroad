import * as React from "react";

import { useDomains } from "$app/components/DomainSettings";

export const Layout = ({ heading, children }: { heading: string; children: React.ReactNode }) => {
  const { rootDomain } = useDomains();

  return (
    <>
      <div className="stack">
        <header>
          <h2>{heading}</h2>
        </header>
        <p>{children}</p>
      </div>
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
