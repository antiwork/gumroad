import { router } from "@inertiajs/react";
import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import AdminActionButton from "$app/components/Admin/ActionButton";
import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

const formatUsd = (cents: number) => formatPriceCentsWithCurrencySymbol("usd", cents, { symbolFormat: "short" });

const formatLastSynced = (isoString: string | null) => {
  if (!isoString) return "Not yet synced";

  const synced = new Date(isoString);
  return `Synced ${synced.toLocaleString()}`;
};

const ActiveWatchView = ({ user }: { user: User }) => {
  const watch = user.active_watched_user;
  if (!watch) return null;

  const progressPercent = Math.min(
    100,
    watch.revenue_threshold_cents > 0 ? Math.round((watch.revenue_cents / watch.revenue_threshold_cents) * 100) : 0,
  );

  return (
    <div className="grid gap-3">
      <div className="grid gap-1">
        <span className="text-xs tracking-wide text-muted uppercase">Revenue since watched</span>
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-base font-medium">
            {formatUsd(watch.revenue_cents)} / {formatUsd(watch.revenue_threshold_cents)}
          </span>
          <span className="text-sm text-muted">{progressPercent}%</span>
        </div>
        <div className="h-2 w-full overflow-hidden rounded bg-muted/40">
          <div
            className="h-full bg-accent"
            style={{ width: `${progressPercent}%` }}
            role="progressbar"
            aria-valuenow={progressPercent}
            aria-valuemin={0}
            aria-valuemax={100}
          />
        </div>
      </div>
      <div className="grid gap-1">
        <span className="text-xs tracking-wide text-muted uppercase">Unpaid balance</span>
        <span className="text-base font-medium">{formatUsd(watch.unpaid_balance_cents)}</span>
      </div>
      {watch.notes ? <p className="text-sm whitespace-pre-wrap">{watch.notes}</p> : null}
      <p className="text-xs text-muted">{formatLastSynced(watch.last_synced_at)}</p>
      <div>
        <AdminActionButton
          label="Remove from watchlist"
          method="DELETE"
          url={Routes.remove_from_watchlist_admin_user_path(user.external_id)}
          loading="Removing..."
          done="Removed"
          success_message="Removed from watchlist."
          confirm_message={`Remove ${user.email} from the watchlist?`}
          outline
        />
      </div>
    </div>
  );
};

const AddToWatchlistForm = ({ user }: { user: User }) => (
  <Form
    url={Routes.add_to_watchlist_admin_user_path(user.external_id)}
    method="POST"
    onSuccess={() => {
      showAlert("Added to watchlist.", "success");
      router.reload();
    }}
  >
    {(isLoading) => (
      <Fieldset>
        <div className="grid gap-3">
          <div className="flex items-end gap-2">
            <div className="flex w-32 flex-col gap-2">
              <Label htmlFor="watched_user_revenue_threshold">Revenue threshold ($)</Label>
              <Input
                id="watched_user_revenue_threshold"
                name="watched_user[revenue_threshold]"
                type="number"
                min="1"
                step="0.01"
                required
                placeholder="200"
              />
            </div>
            <Button type="submit" disabled={isLoading}>
              {isLoading ? "Adding..." : "Add to watchlist"}
            </Button>
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor="watched_user_notes">Notes (optional)</Label>
            <Textarea
              id="watched_user_notes"
              name="watched_user[notes]"
              rows={3}
              placeholder="What to look for on the next review"
            />
          </div>
        </div>
      </Fieldset>
    )}
  </Form>
);

const WatchedUser = ({ user }: { user: User }) => (
  <>
    <hr />
    <Details open={!!user.active_watched_user}>
      <DetailsToggle>
        <h3>Watchlist</h3>
      </DetailsToggle>
      {user.active_watched_user ? <ActiveWatchView user={user} /> : <AddToWatchlistForm user={user} />}
    </Details>
  </>
);

export default WatchedUser;
