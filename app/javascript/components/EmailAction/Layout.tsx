import * as React from "react";

import { useDomains } from "$app/components/DomainSettings";
import { Stack, StackItem } from "$app/components/ui/Stack";

export const Layout = ({ heading, children }: { heading: string; children: React.ReactNode }) => {
  const { rootDomain } = useDomains();

  return (
    <>
      <Stack>
        <StackItem as="header">
          <h2 className="grow">{heading}</h2>
        </StackItem>
        <StackItem as="p">{children}</StackItem>
      </Stack>
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
