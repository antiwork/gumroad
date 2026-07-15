import * as React from "react";

import { PreviewChrome, PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
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
        <PreviewSidebar>
          {/* Workflow emails land in inboxes, not on a page — there's no public URL to show
              or open, so the chrome carries the workflow's name alone. */}
          <PreviewChrome title={title}>
            <div className="flex flex-col gap-4 p-4">{preview}</div>
          </PreviewChrome>
        </PreviewSidebar>
      </WithPreviewSidebar>
    ) : (
      <div>{children}</div>
    )}
  </>
);
