import { Link } from "@inertiajs/react";
import React from "react";

import { EmailTab } from "$app/data/installments";

import { Button, buttonVariants } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

type LayoutProps = {
  selectedTab: EmailTab;
  children: React.ReactNode;
  hasPosts?: boolean;
  query?: string;
  onQueryChange?: (query: string) => void;
  hideNewButton?: boolean;
};

export const EmailsLayout = ({ selectedTab, children, hasPosts, query, onQueryChange, hideNewButton }: LayoutProps) => {
  const searchInputRef = React.useRef<HTMLInputElement>(null);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  return (
    <div>
      <PageHeader
        title="Emails"
        actions={
          <>
            {hasPosts && onQueryChange ? (
              <Popover
                open={isSearchPopoverOpen}
                onToggle={setIsSearchPopoverOpen}
                aria-label="Toggle Search"
                trigger={
                  <WithTooltip tip="Search" position="bottom">
                    <div className={buttonVariants({ size: "default" })}>
                      <Icon name="solid-search" />
                    </div>
                  </WithTooltip>
                }
              >
                <div className="input">
                  <Icon name="solid-search" />
                  <input
                    ref={searchInputRef}
                    type="text"
                    placeholder="Search emails"
                    value={query ?? ""}
                    onChange={(evt) => onQueryChange(evt.target.value)}
                  />
                </div>
              </Popover>
            ) : null}
            {!hideNewButton && <NewEmailButton />}
          </>
        }
      >
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
          <Tab href={Routes.followers_path()} isSelected={false}>
            Subscribers
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
