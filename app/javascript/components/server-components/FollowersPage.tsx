import debounce from "lodash/debounce";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { deleteFollower, fetchFollowers, Follower } from "$app/data/followers";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover } from "$app/components/Popover";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { ExportSubscribersPopover } from "$app/components/server-components/FollowersPage/ExportSubscribersPopover";
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
    <main>
      <header>
        <h1>{title}</h1>
        {actions ? <div className="actions">{actions}</div> : null}
        <div role="tablist">
          <a href={`${Routes.emails_path()}/published`} role="tab">
            Published
          </a>
          {loggedInUser?.policies.installment.create ? (
            <>
              <a href={`${Routes.emails_path()}/scheduled`} role="tab">
                Scheduled
              </a>
              <a href={`${Routes.emails_path()}/drafts`} role="tab">
                Drafts
              </a>
            </>
          ) : null}
          <a href={Routes.followers_path()} role="tab" aria-selected="true">
            Subscribers
          </a>
        </div>
      </header>
      {children}
    </main>
  );
};

type Props = { followers: Follower[]; per_page: number; total: number };

export const FollowersPage = ({ followers: initialFollowers, per_page, total }: Props) => {
  const userAgentInfo = useUserAgentInfo();

  const [loading, setLoading] = React.useState(false);
  const [followers, setFollowers] = React.useState<Follower[]>(initialFollowers);
  const [selectedFollowerId, setSelectedFollowerId] = React.useState<string | null>(null);
  const [searchBoxOpen, setSearchBoxOpen] = React.useState(false);
  const [searchQuery, setSearchQuery] = React.useState("");
  const [totalCount, setTotalCount] = React.useState(total);
  const [totalFilteredCount, setTotalFilteredCount] = React.useState(total);
  const [removing, setRemoving] = React.useState(false);
  const [page, setPage] = React.useState(1);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const selectedFollower = followers.find((follower) => follower.id === selectedFollowerId);

  React.useEffect(() => {
    if (searchBoxOpen) searchInputRef.current?.focus();
  }, [searchBoxOpen]);

  const loadFollowers = async (email: string, page = 1) => {
    try {
      const response = await fetchFollowers({ email, page });
      setPage(page);
      setFollowers(page === 1 ? response.paged_followers : [...followers, ...response.paged_followers]);
      setTotalFilteredCount(response.total_count);
    } catch {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
    setLoading(false);
  };

  const debouncedLoadFollowers = React.useCallback(debounce(loadFollowers, 500), []);
  React.useEffect(() => {
    setLoading(true);
    void debouncedLoadFollowers(searchQuery);
  }, [searchQuery]);

  const removeFollower = async (id: string) => {
    setRemoving(true);
    try {
      await deleteFollower(id);
      setTotalCount(totalCount - 1);
      setTotalFilteredCount(totalFilteredCount - 1);
      setFollowers(followers.filter((follower) => follower.id !== id));
      setSelectedFollowerId(null);
      showAlert("Follower removed!", "success");
    } catch {
      showAlert("Failed to remove follower.", "error");
    }
    setRemoving(false);
  };

  const currentSeller = useCurrentSeller();

  return (
    <Layout
      title="Subscribers"
      actions={
        <>
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
      <div>
        {loading ? (
          <div className="flex justify-center">
            <Progress width="5rem" />
          </div>
        ) : followers.length > 0 ? (
          <div>
            <table>
              <caption>All subscribers ({totalCount.toLocaleString(userAgentInfo.locale)})</caption>
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Date Added</th>
                </tr>
              </thead>
              <tbody>
                {followers.map((follower) => (
                  <tr
                    key={follower.id}
                    onClick={() => setSelectedFollowerId(follower.id === selectedFollowerId ? null : follower.id)}
                    aria-selected={selectedFollowerId === follower.id}
                  >
                    <td data-label="Email">{follower.email}</td>
                    <td data-label="Date Added">{follower.formatted_confirmed_on}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {page * per_page < totalFilteredCount ? (
              <Button
                color="primary"
                onClick={() => void loadFollowers(searchQuery, page + 1)}
                style={{ marginTop: "var(--spacer-5)" }}
              >
                Load more
              </Button>
            ) : null}
            {selectedFollower ? (
              <aside className={selectedFollower.can_update ? "" : "js-team-member-read-only"}>
                <header>
                  <h2>Details</h2>
                  <button className="close" onClick={() => setSelectedFollowerId(null)} title="Close" />
                </header>
                <div className="stack">
                  <div>
                    <div>
                      <h4>Email</h4>
                      <div>{selectedFollower.email}</div>
                      <Button
                        color="danger"
                        onClick={() => void removeFollower(selectedFollower.id)}
                        disabled={removing}
                        style={{ marginTop: "var(--spacer-2)" }}
                      >
                        {removing ? "Removing..." : "Remove follower"}
                      </Button>
                    </div>
                  </div>
                </div>
              </aside>
            ) : null}
          </div>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
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
          </div>
        )}
      </div>
    </Layout>
  );
};

export default register({ component: FollowersPage, propParser: createCast() });
