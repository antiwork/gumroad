import { router } from "@inertiajs/react";
import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import AdminActionButton from "$app/components/Admin/ActionButton";
import { Form } from "$app/components/Admin/Form";
import type { ActiveWatchedUser, User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

const formatUsd = (cents: number) => formatPriceCentsWithCurrencySymbol("usd", cents, { symbolFormat: "short" });

const formatLastSynced = (isoString: string | null) => {
  if (!isoString) return "Not yet synced";

  const synced = new Date(isoString);
  return `Synced ${synced.toLocaleString()}`;
};

const dollarsValue = (cents: number) => (cents / 100).toString();

const WatchedBanner = ({ watch }: { watch: ActiveWatchedUser }) => {
  const progressPercent = Math.min(
    100,
    watch.revenue_threshold_cents > 0 ? Math.round((watch.revenue_cents / watch.revenue_threshold_cents) * 100) : 0,
  );

  return (
    <Alert variant="info">
      <div className="grid gap-3">
        <div className="font-medium">This user is currently being watched.</div>
        <div className="grid gap-1">
          <span className="text-xs tracking-wide text-muted uppercase">Total revenue</span>
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
        <p className="text-xs text-muted">{formatLastSynced(watch.last_synced_at)}</p>
      </div>
    </Alert>
  );
};

const WatchlistForm = ({ user }: { user: User }) => {
  const watch = user.active_watched_user;
  const url = watch
    ? Routes.update_watchlist_admin_user_path(user.external_id)
    : Routes.add_to_watchlist_admin_user_path(user.external_id);
  const submitLabel = watch ? "Update" : "Add to watchlist";
  const submittingLabel = watch ? "Updating..." : "Adding...";
  const successMessage = watch ? "Watchlist updated." : "Added to watchlist.";

  return (
    <Form
      url={url}
      method="POST"
      onSuccess={() => {
        showAlert(successMessage, "success");
        router.reload();
      }}
    >
      {(isLoading) => (
        <Fieldset>
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
                defaultValue={watch ? dollarsValue(watch.revenue_threshold_cents) : ""}
                placeholder="200"
              />
            </div>
            <div className="flex flex-1 flex-col gap-2">
              <Label htmlFor="watched_user_notes">Notes (optional)</Label>
              <Input
                id="watched_user_notes"
                name="watched_user[notes]"
                type="text"
                defaultValue={watch?.notes ?? ""}
                placeholder="What to look for on the next review"
              />
            </div>
            <Button type="submit" disabled={isLoading}>
              {isLoading ? submittingLabel : submitLabel}
            </Button>
          </div>
        </Fieldset>
      )}
    </Form>
  );
};

const WatchedUser = ({ user }: { user: User }) => {
  const watch = user.active_watched_user;

  return (
    <>
      <hr />
      <Details open={!!watch}>
        <DetailsToggle>
          <h3>Watchlist</h3>
        </DetailsToggle>
        <div className="grid gap-3">
          {watch ? <WatchedBanner watch={watch} /> : null}
          <WatchlistForm user={user} />
          {watch ? (
            <div>
              <AdminActionButton
                label="Remove from watchlist"
                method="DELETE"
                url={Routes.remove_from_watchlist_admin_user_path(user.external_id)}
                loading="Removing..."
                done="Removed"
                success_message="Removed from watchlist."
                confirm_message={`Remove ${user.email} from the watchlist?`}
                color="danger"
              />
            </div>
          ) : null}
        </div>
      </Details>
    </>
  );
};

export default WatchedUser;
