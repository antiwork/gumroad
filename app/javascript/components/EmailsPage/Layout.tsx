import { Link } from "@inertiajs/react";
import React from "react";

import { EmailTab } from "$app/data/installments";

import { Button } from "$app/components/Button";
import { Search } from "$app/components/Search";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

type LayoutProps = {
  selectedTab: EmailTab;
  children: React.ReactNode;
  hasPosts?: boolean;
  query?: string;
  onQueryChange?: (query: string) => void;
  hideNewButton?: boolean;
  actions?: React.ReactNode;
};

export const EmailsLayout = ({
  selectedTab,
  children,
  hasPosts,
  query,
  onQueryChange,
  hideNewButton,
  actions,
}: LayoutProps) => {
  const title = selectedTab === "subscribers" ? "Subscribers" : "Emails";

  const defaultActions = (
    <>
      {hasPosts && onQueryChange ? (
        <Search value={query ?? ""} onSearch={onQueryChange} placeholder="Search emails" />
      ) : null}
      {!hideNewButton && <NewEmailButton />}
    </>
  );

  return (
    <div>
      <PageHeader title={title} actions={actions ?? defaultActions}>
        <Tabs>
          <Tab asChild isSelected={selectedTab === "published"}>
            <Link href={Routes.published_emails_path()}>Published</Link>
          </Tab>
          <Tab asChild isSelected={selectedTab === "scheduled"}>
            <Link href={Routes.scheduled_emails_path()}>Scheduled</Link>
          </Tab>
          <Tab asChild isSelected={selectedTab === "drafts"}>
            <Link href={Routes.drafts_emails_path()}>Drafts</Link>
          </Tab>
          <Tab asChild isSelected={selectedTab === "subscribers"}>
            <Link href={Routes.followers_path()}>Subscribers</Link>
          </Tab>
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};

export const NewEmailButton = ({ copyFrom }: { copyFrom?: string } = {}) => {
  const href = copyFrom ? Routes.new_email_path({ copy_from: copyFrom }) : Routes.new_email_path();

  return (
    <Button asChild color={copyFrom ? undefined : "accent"}>
      <Link href={href}>{copyFrom ? "Duplicate" : "New email"}</Link>
    </Button>
  );
};
export const EditEmailButton = ({ id }: { id: string }) => (
  <Button asChild>
    <Link href={Routes.edit_email_path(id)}>Edit</Link>
  </Button>
);
