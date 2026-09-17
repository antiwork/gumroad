import { Envelope, Instagram, Tiktok, TwitterX, Youtube } from "@boxicons/react";
import * as React from "react";

import {
  approveMarketingAction,
  cancelMarketingAction,
  executeMarketingAction,
  fetchMarketingRecommendations,
  type MarketingAction,
  type MarketingChannel,
} from "$app/data/marketing_actions";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Pill } from "$app/components/ui/Pill";
import { Textarea } from "$app/components/ui/Textarea";

const CHANNEL_ICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  x: TwitterX,
  instagram: Instagram,
  youtube: Youtube,
  tiktok: Tiktok,
  email: Envelope,
};

const EMAIL_DRAFT_STATE_LABELS: Record<NonNullable<MarketingChannel["draft"]>["state"], string> = {
  draft: "Draft",
  scheduled: "Scheduled",
  published: "Published",
  sending: "Sending",
  waiting: "Waiting",
  incomplete: "Incomplete",
  sent: "Send complete",
};

// Blast completion records processing by the email provider, not inbox delivery.
const EMAIL_DRAFT_SUMMARY: Record<NonNullable<MarketingChannel["draft"]>["state"], (subject: string) => string> = {
  draft: () => "Launch email drafted for your saved audience.",
  scheduled: (subject) => `Your launch email about ${subject} is scheduled for your audience.`,
  published: (subject) => `Your launch post about ${subject} is published.`,
  sending: (subject) => `Your launch email about ${subject} is being processed. Check delivery details in Emails.`,
  waiting: (subject) =>
    `Your launch email about ${subject} is waiting to be processed. Check delivery details in Emails.`,
  incomplete: (subject) =>
    `Your launch email about ${subject} has not finished processing. Check delivery details in Emails.`,
  sent: (subject) => `Email processing is complete for ${subject}. Check delivery details in Emails.`,
};

const pluralize = (count: number, singular: string, plural: string) => (count === 1 ? singular : plural);

// One line, naming the product once: the card already sits on the product's own page.
const draftSummary = (counts: NonNullable<MarketingChannel["counts"]>) => {
  const segments = [
    `${counts.customers} past ${pluralize(counts.customers, "customer", "customers")}`,
    `${counts.followers} ${pluralize(counts.followers, "follower", "followers")}`,
  ];
  if (counts.affiliates > 0)
    segments.push(`${counts.affiliates} ${pluralize(counts.affiliates, "affiliate", "affiliates")}`);
  return `Launch email drafted for ${counts.total} ${pluralize(counts.total, "person", "people")} (${segments.join(", ")}) in the draft's saved audience.`;
};

const formatUSD = (cents: number) =>
  formatPriceCentsWithCurrencySymbol("usd", cents, { symbolFormat: "short", noCentsIfWhole: true });

export const ShareYourLaunchCard = ({ productPermalink }: { productPermalink: string }) => (
  <LaunchComposer key={productPermalink} productPermalink={productPermalink} />
);

const NetworkIcon = ({ channel }: { channel: string }) => {
  const Icon = { x: TwitterX, instagram: Instagram, youtube: Youtube, tiktok: Tiktok }[channel];
  return Icon ? <Icon className="size-5 shrink-0" aria-hidden="true" /> : null;
};

const LaunchComposer = ({ productPermalink }: { productPermalink: string }) => {
  const [channels, setChannels] = React.useState<MarketingChannel[] | null>(null);
  const [selectedChannel, setSelectedChannel] = React.useState<string | null>(null);
  const [drafts, setDrafts] = React.useState<Record<string, string>>({});
  const [busy, setBusy] = React.useState(false);
  const destinationId = React.useId();

  React.useEffect(() => {
    let current = true;
    void fetchMarketingRecommendations(productPermalink)
      .then((result) => {
        if (current) setChannels(result);
      })
      .catch((e: unknown) => {
        assertResponseError(e);
        if (current) setChannels([]);
      });
    return () => {
      current = false;
    };
  }, [productPermalink]);

  const liveChannels =
    channels?.filter((channel) => channel.live && channel.action && channel.channel !== "email") ?? [];
  const emailChannel = channels?.find((channel) => channel.channel === "email" && channel.live && channel.action);
  const channel = liveChannels.find((item) => item.channel === selectedChannel) ?? liveChannels[0];
  const action = channel?.action;
  if ((!channel || !action) && !emailChannel) return null;

  return (
    <section className="grid gap-4">
      <header>
        <h2>Share your launch</h2>
        <p className="text-muted">Review your post before sharing it.</p>
      </header>
      <Card>
        {channel && action ? (
          <>
            {liveChannels.length > 1 ? (
              <CardContent details>
                <fieldset>
                  <legend className="mb-2">Post to</legend>
                  <div className="flex flex-wrap gap-2">
                    {liveChannels.map((item) => (
                      <label key={item.channel} className="cursor-pointer">
                        <input
                          type="radio"
                          name={destinationId}
                          value={item.channel}
                          checked={channel.channel === item.channel}
                          onChange={() => setSelectedChannel(item.channel)}
                          disabled={busy}
                          className="peer sr-only"
                        />
                        <span className="flex min-h-11 items-center gap-2 rounded border border-border px-3 peer-checked:bg-foreground peer-checked:text-background peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent peer-disabled:cursor-not-allowed">
                          <NetworkIcon channel={item.channel} />
                          {item.label}
                        </span>
                      </label>
                    ))}
                  </div>
                </fieldset>
              </CardContent>
            ) : null}
            <ChannelComposer
              key={action.id}
              channel={channel}
              action={action}
              copy={drafts[action.id] ?? action.copy}
              onCopyChange={(copy) => setDrafts((previous) => ({ ...previous, [action.id]: copy }))}
              showNetworkName={liveChannels.length === 1}
              productPermalink={productPermalink}
              busy={busy}
              onBusyChange={setBusy}
              onChange={(updatedAction) =>
                setChannels(
                  (previous) =>
                    previous?.map((item) =>
                      item.channel === channel.channel ? { ...item, action: updatedAction } : item,
                    ) ?? null,
                )
              }
            />
          </>
        ) : null}
        {emailChannel ? <EmailChannelRow channel={emailChannel} /> : null}
      </Card>
    </section>
  );
};

const ChannelIcon = ({ channel, className }: { channel: string; className: string }) => {
  const Icon = CHANNEL_ICONS[channel];
  return Icon ? <Icon className={className} /> : null;
};

const EmailChannelRow = ({ channel }: { channel: MarketingChannel }) => {
  const counts = channel.counts;
  const draft = channel.draft;

  return (
    <CardContent details className="grid gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-3">
          <ChannelIcon channel="email" className="size-6" />
          <span className="font-semibold">{channel.label}</span>
        </div>
        {draft ? <Pill size="small">{EMAIL_DRAFT_STATE_LABELS[draft.state]}</Pill> : null}
      </div>

      {channel.eligible === false ? (
        <Alert role="status">
          <span>
            {channel.blocked_reason}
            {channel.requirements &&
            channel.requirements.sales_cents_total < channel.requirements.min_sales_cents_required
              ? ` You're at ${formatUSD(channel.requirements.sales_cents_total)} of ${formatUSD(channel.requirements.min_sales_cents_required)} in sales.`
              : null}
          </span>
        </Alert>
      ) : channel.declined ? (
        <Alert role="status">
          <span>You deleted the launch email for this product, so we won&apos;t create another one.</span>
        </Alert>
      ) : draft ? (
        <>
          <span>
            {draft.state === "draft" && counts ? draftSummary(counts) : EMAIL_DRAFT_SUMMARY[draft.state](draft.subject)}
          </span>
          <div className="flex flex-wrap gap-2">
            <NavigationButton href={draft.edit_url}>
              {draft.state === "draft" ? "Review the draft" : "Open in Emails"}
            </NavigationButton>
          </div>
        </>
      ) : (
        <Alert role="status">
          <span>We couldn&apos;t prepare the draft. You can still write one yourself in Emails.</span>
        </Alert>
      )}
    </CardContent>
  );
};

const ChannelComposer = ({
  channel,
  action,
  productPermalink,
  onChange,
  copy,
  onCopyChange,
  showNetworkName,
  busy,
  onBusyChange,
}: {
  channel: MarketingChannel;
  action: MarketingAction;
  productPermalink: string;
  onChange: (action: MarketingAction) => void;
  copy: string;
  onCopyChange: (copy: string) => void;
  showNetworkName: boolean;
  busy: boolean;
  onBusyChange: (busy: boolean) => void;
}) => {
  const [confirming, setConfirming] = React.useState(false);
  const [intentUrl, setIntentUrl] = React.useState<string | undefined>(channel.intent_url);
  const edited = copy !== action.copy;
  const terminal = action.status === "posted" || action.status === "failed" || action.status === "cancelled";

  const run = async (fn: () => Promise<void>) => {
    onBusyChange(true);
    try {
      await fn();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      onBusyChange(false);
    }
  };

  const confirmAndPost = () =>
    run(async () => {
      const approved = await approveMarketingAction(productPermalink, action.id, edited ? copy : undefined);
      onChange(approved);
      const result = await executeMarketingAction(productPermalink, action.id);
      setIntentUrl(result.intent_url ?? undefined);
      onChange(result.action);
      setConfirming(false);
      if (result.action.status === "posted") showAlert(`Posted on ${channel.label}!`, "success");
    });

  return (
    <CardContent details className="grid gap-4">
      {showNetworkName || (channel.connected && channel.handle) || terminal ? (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-3">
            {showNetworkName ? (
              <>
                <NetworkIcon channel={channel.channel} />
                <span className="font-semibold">{channel.label}</span>
              </>
            ) : null}
            {channel.connected && channel.handle ? (
              <span className="text-muted">Posting as @{channel.handle}</span>
            ) : null}
          </div>
          {action.status === "posted" ? (
            <Pill color="success" size="small">
              Posted
            </Pill>
          ) : action.status === "cancelled" ? (
            <Pill size="small">Cancelled</Pill>
          ) : null}
        </div>
      ) : null}

      {action.status === "posted" ? (
        <Alert role="status" variant="success">
          <div className="flex flex-col justify-between gap-2 sm:flex-row">
            <span>Your launch post is live.</span>
            {action.external_url ? (
              <a href={action.external_url} target="_blank" rel="noreferrer">
                View post on {channel.label}
              </a>
            ) : null}
          </div>
        </Alert>
      ) : null}

      {action.error_code === "x_write_permission_missing" && channel.connected ? (
        <Alert role="status" variant="warning">
          <div className="grid gap-2">
            <span>
              Gumroad can't post for you yet: your connected X account only allows reading. Post it yourself, or
              reconnect X to let Gumroad post for you.
            </span>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={action.link_url ?? ""} text={action.copy} />
              <NavigationButton href={channel.connect_path}>Reconnect X</NavigationButton>
            </div>
          </div>
        </Alert>
      ) : action.error_code === "x_post_result_unknown" ? (
        <Alert role="status" variant="warning">
          <div className="flex flex-col justify-between gap-2 sm:flex-row">
            <span>We couldn't confirm whether this post went through. Check your X account before posting again.</span>
            <TwitterShareButton url={action.link_url ?? ""} text={action.copy} />
          </div>
        </Alert>
      ) : action.status === "failed" ? (
        <Alert role="status" variant="danger">
          <div className="flex flex-col justify-between gap-2 sm:flex-row">
            <span>The post didn't go through ({action.error_code}). You can still post it yourself.</span>
            {channel.channel === "x" ? <TwitterShareButton url={action.link_url ?? ""} text={action.copy} /> : null}
          </div>
        </Alert>
      ) : null}

      {!terminal ? (
        <>
          <fieldset>
            <label htmlFor={`marketing-copy-${action.id}`}>Post text</label>
            <Textarea
              id={`marketing-copy-${action.id}`}
              value={copy}
              onChange={(e) => onCopyChange(e.target.value)}
              maxLength={255}
              rows={3}
            />
            <small className="text-muted">
              Your product link is added automatically. Sales from this post appear in your analytics.
            </small>
          </fieldset>

          {channel.connected ? (
            <div className="flex flex-wrap gap-2">
              <Button color="primary" disabled={busy || copy.trim() === ""} onClick={() => setConfirming(true)}>
                Post on {channel.label}
              </Button>
              <Button
                disabled={busy}
                onClick={() =>
                  void run(async () => {
                    onChange(await cancelMarketingAction(productPermalink, action.id));
                  })
                }
              >
                Dismiss
              </Button>
            </div>
          ) : (
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
              {channel.channel === "x" && intentUrl ? (
                <TwitterShareButton url={action.link_url ?? ""} text={copy}>
                  Continue on X
                </TwitterShareButton>
              ) : null}
              <a href={channel.connect_path} className="flex min-h-11 items-center">
                Connect {channel.label} for direct posting
              </a>
            </div>
          )}
        </>
      ) : null}

      {confirming ? (
        <Modal
          open
          onClose={() => {
            if (!busy) setConfirming(false);
          }}
          allowClose={!busy}
          title={`Post on ${channel.label}?`}
          footer={
            <>
              <Button disabled={busy} onClick={() => setConfirming(false)}>
                Cancel
              </Button>
              <Button color="primary" disabled={busy} onClick={() => void confirmAndPost()}>
                {busy ? "Posting..." : "Post now"}
              </Button>
            </>
          }
        >
          <div className="grid gap-3">
            <p>
              This will post from <strong>@{channel.handle}</strong> right away. Published posts can't be recalled from
              here.
            </p>
            <blockquote className="rounded border border-border p-3 whitespace-pre-wrap">
              {copy}
              {"\n\n"}
              {action.link_url}
            </blockquote>
          </div>
        </Modal>
      ) : null}
    </CardContent>
  );
};
