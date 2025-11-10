import * as React from "react";

import { PageHeader } from "$app/components/ui/PageHeader";

type LayoutProps = {
  title: string;
  actions?: React.ReactNode;
  navigation?: React.ReactNode;
  children: React.ReactNode;
  preview?: React.ReactNode;
};

export const Layout = ({ title, actions, navigation, children, preview }: LayoutProps) => (
  <>
    <PageHeader className="sticky-top" title={title} actions={actions}>
      {navigation ?? null}
    </PageHeader>
    {preview ? (
      <div className="fixed-aside flex-1 lg:grid lg:grid-cols-[1fr_30vw]">
        <div>{children}</div>
        <aside className="hidden max-h-screen lg:sticky!" aria-label="Preview">
          {preview}
        </aside>
      </div>
    ) : (
      <div>{children}</div>
    )}
  </>
);
