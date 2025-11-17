import * as React from "react";

import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
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
      <WithPreviewSidebar className="flex-1">
        <div>{children}</div>
        <PreviewSidebar>{preview}</PreviewSidebar>
      </WithPreviewSidebar>
    ) : (
      <div>{children}</div>
    )}
  </>
);
