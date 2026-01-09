import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { ExportSubscribersPopover } from "$app/components/Followers/ExportSubscribersPopover";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/followers.png";

const Layout = ({
  title,
  actions,
  children,
}: {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
}) => {
  const loggedInUser = useLoggedInUser();

  return (
    <div>
      <PageHeader title={title} actions={actions}>
        <Tabs>
          <Tab href={Routes.published_emails_path()} isSelected={false}>
            Published
          </Tab>
          {loggedInUser?.policies.installment.create ? (
            <>
              <Tab href={Routes.scheduled_emails_path()} isSelected={false}>
                Scheduled
              </Tab>
              <Tab href={Routes.drafts_emails_path()} isSelected={false}>
                Drafts
              </Tab>
            </>
          ) : null}
          <Tab href={Routes.followers_path()} isSelected>
            Subscribers
          </Tab>
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};

type Follower = {
  id: string;
  email: string;
  created_at: string;
  source: string | null;
  formatted_confirmed_on: string;
  can_update: boolean | null;
};

type Props = {
  followers: Follower[];
  total_count: number;
  page: number;
  has_more: boolean;
  email: string;
};

export default function FollowersPage() {
  const { followers, total_count, page, has_more, email } = cast<Props>(usePage().props);
  const userAgentInfo = useUserAgentInfo();

  const [isLoadingMore, setIsLoadingMore] = React.useState(false);
  const [selectedFollowerId, setSelectedFollowerId] = React.useState<string | null>(null);
  const [searchBoxOpen, setSearchBoxOpen] = React.useState(false);
  const [searchQuery, setSearchQuery] = React.useState(email);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const selectedFollower = followers.find((follower) => follower.id === selectedFollowerId);

  React.useEffect(() => {
    if (searchBoxOpen) searchInputRef.current?.focus();
  }, [searchBoxOpen]);

  const updateSearch = useDebouncedCallback((email: string) => {
    router.reload({
      data: { email: email || undefined, page: 1 },
      reset: ["followers", "has_more"],
      preserveUrl: true,
    });
  }, 500);

  React.useEffect(() => {
    if (searchQuery !== email) {
      updateSearch(searchQuery);
    }
  }, [searchQuery, email, updateSearch]);

  const loadMore = () => {
    if (!has_more || isLoadingMore) return;
    router.reload({
      data: { email: searchQuery || undefined, page: page + 1 },
      only: ["followers", "has_more", "page"],
      preserveUrl: true,
      onStart: () => setIsLoadingMore(true),
      onFinish: () => setIsLoadingMore(false),
    });
  };

  const deleteForm = useForm({});
  const removeFollower = (id: string) => {
    deleteForm.delete(Routes.follower_path(id), {
      preserveScroll: true,
      onSuccess: () => setSelectedFollowerId(null),
      onError: () => showAlert("Failed to remove follower.", "error"),
    });
  };

  const currentSeller = useCurrentSeller();

  return (
    <Layout
      title="Subscribers"
      actions={
        <>
          {(followers.length > 0 || searchQuery.length > 0) && (
            <Popover
              open={searchBoxOpen}
              onToggle={setSearchBoxOpen}
              aria-label="Search"
              trigger={
                <WithTooltip tip="Search" position="bottom">
                  <div className="button">
                    <Icon name="solid-search" />
                  </div>
                </WithTooltip>
              }
            >
              <input
                ref={searchInputRef}
                value={searchQuery}
                autoFocus
                type="text"
                placeholder="Search followers"
                onChange={(evt) => setSearchQuery(evt.target.value)}
              />
            </Popover>
          )}
          <Popover
            aria-label="Export"
            trigger={
              <WithTooltip tip="Export" position="bottom">
                <Button aria-label="Export">
                  <Icon aria-label="Download" name="download" />
                </Button>
              </WithTooltip>
            }
          >
            {(close) => <ExportSubscribersPopover closePopover={close} />}
          </Popover>

          {currentSeller ? (
            <CopyToClipboard
              tooltipPosition="bottom"
              text={Routes.custom_domain_subscribe_url({ host: currentSeller.subdomain })}
            >
              <Button>
                <Icon name="link" />
                Share subscribe page
              </Button>
            </CopyToClipboard>
          ) : null}
        </>
      }
    >
      <div className="space-y-4 p-4 md:p-8">
        {followers.length > 0 ? (
          <div>
            <Table>
              <TableCaption>All subscribers ({total_count.toLocaleString(userAgentInfo.locale)})</TableCaption>
              <TableHeader>
                <TableRow>
                  <TableHead>Email</TableHead>
                  <TableHead>Date Added</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {followers.map((follower) => (
                  <TableRow
                    key={follower.id}
                    onClick={() => setSelectedFollowerId(follower.id === selectedFollowerId ? null : follower.id)}
                    selected={selectedFollowerId === follower.id}
                  >
                    <TableCell>{follower.email}</TableCell>
                    <TableCell>{follower.formatted_confirmed_on}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {has_more ? (
              <Button color="primary" onClick={loadMore} disabled={isLoadingMore} className="mt-6">
                {isLoadingMore ? "Loading..." : "Load more"}
              </Button>
            ) : null}
            {selectedFollower ? (
              <Sheet
                open
                onOpenChange={() => setSelectedFollowerId(null)}
                className={selectedFollower.can_update ? "" : "js-team-member-read-only"}
              >
                <SheetHeader>Details</SheetHeader>
                <div className="stack">
                  <div>
                    <div>
                      <h4>Email</h4>
                      <div>{selectedFollower.email}</div>
                      <Button
                        color="danger"
                        onClick={() => removeFollower(selectedFollower.id)}
                        disabled={deleteForm.processing}
                        className="mt-2"
                      >
                        {deleteForm.processing ? "Removing..." : "Remove follower"}
                      </Button>
                    </div>
                  </div>
                </div>
              </Sheet>
            ) : null}
          </div>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            {searchQuery.length === 0 ? (
              <>
                <h2>Manage all of your followers in one place.</h2>
                Interacting with and serving your audience is an important part of running your business.
                {currentSeller ? (
                  <CopyToClipboard
                    tooltipPosition="bottom"
                    text={Routes.custom_domain_subscribe_url({ host: currentSeller.subdomain })}
                  >
                    <Button color="accent">Share subscribe page</Button>
                  </CopyToClipboard>
                ) : null}
                <p>
                  or{" "}
                  <a href="/help/article/170-audience" target="_blank" rel="noreferrer">
                    learn more about the audience dashboard
                  </a>
                </p>
              </>
            ) : (
              <h2>No followers found</h2>
            )}
          </Placeholder>
        )}
      </div>
    </Layout>
  );
}
