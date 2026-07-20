import * as React from "react";

import { PreviewChrome, PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { PageHeader } from "$app/components/ui/PageHeader";

type LayoutProps = {
  title: string;
  actions?: React.ReactNode;
  navigation?: React.ReactNode;
  children: React.ReactNode;
  preview?: React.ReactNode;
  // The sender line the workflow's emails actually go out with (from the server's mailer
  // config) — required whenever a preview is shown, since the preview is of emails.
  emailFrom?: string;
};

export const Layout = ({ title, actions, navigation, children, preview, emailFrom }: LayoutProps) => (
  <>
    <PageHeader className="sticky-top" title={title} actions={actions}>
      {navigation ?? null}
    </PageHeader>
    {preview && emailFrom ? (
      <WithPreviewSidebar className="flex-1">
        <div>{children}</div>
        <PreviewSidebar>
          {/* Workflow emails land in inboxes, so the chrome shows the real From line instead
              of browser chrome. No Subject here: the pane stacks every email in the workflow,
              each carrying its own subject as its heading, so a single Subject line in the
              chrome would be ambiguous (or made up). */}
          <PreviewChrome variant="email" from={emailFrom}>
            <div className="flex flex-col gap-4 p-4">{preview}</div>
          </PreviewChrome>
        </PreviewSidebar>
      </WithPreviewSidebar>
    ) : (
      <div>{children}</div>
    )}
  </>
);
