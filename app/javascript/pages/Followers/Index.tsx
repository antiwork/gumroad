import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { EmailsLayout } from "$app/components/EmailsPage/Layout";
import { ExportSubscribersPopover } from "$app/components/Followers/ExportSubscribersPopover";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Search } from "$app/components/Search";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/followers.png";

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
  const [searchQuery, setSearchQuery] = React.useState(email);
  const selectedFollower = followers.find((follower) => follower.id === selectedFollowerId);

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
    <EmailsLayout
      selectedTab="subscribers"
      actions={
        <>
          {(followers.length > 0 || searchQuery.length > 0) && (
            <Search onSearch={setSearchQuery} value={searchQuery} placeholder="Search followers" />
          )}
          <Popover>
            <PopoverAnchor>
              <WithTooltip tip="Export" position="bottom">
                <PopoverTrigger aria-label="Export" asChild>
                  <Button>
                    <Icon aria-label="Download" name="download" />
                  </Button>
                </PopoverTrigger>
              </WithTooltip>
            </PopoverAnchor>
            <PopoverContent sideOffset={4}>
              <ExportSubscribersPopover />
            </PopoverContent>
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
                <Card>
                  <CardContent>
                    <div className="grow">
                      <h4 className="font-bold">Email</h4>
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
                  </CardContent>
                </Card>
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
    </EmailsLayout>
  );
}
