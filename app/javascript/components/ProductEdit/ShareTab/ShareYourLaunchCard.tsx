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
  sent: "Sent",
};

// The row's summary is the seller's status line, so it follows the state: a draft awaits them, a
// scheduled one is queued, and a submitted one is out of their hands — "sent" would claim a
// delivery we do not observe, so it points at the Emails tab for that.
const EMAIL_DRAFT_SUMMARY: Record<NonNullable<MarketingChannel["draft"]>["state"], (subject: string) => string> = {
  draft: (subject) =>
    `We drafted an email about ${subject} for your past customers and followers. Nothing is sent until you send it.`,
  scheduled: (subject) => `Your launch email about ${subject} is scheduled for your past customers and followers.`,
  sent: (subject) => `You submitted your launch email about ${subject}. Check its delivery status in Emails.`,
};

export const ShareYourLaunchCard = ({ productPermalink }: { productPermalink: string }) => {
  const [channels, setChannels] = React.useState<MarketingChannel[] | null>(null);

  React.useEffect(() => {
    void fetchMarketingRecommendations(productPermalink)
      .then(setChannels)
      .catch((e: unknown) => {
        assertResponseError(e);
        setChannels([]);
      });
  }, [productPermalink]);

  if (channels === null || channels.length === 0) return null;

  return (
    <section className="grid gap-4">
      <header>
        <h2>Share your launch</h2>
        <p className="text-muted">Tell people about it. Nothing is posted until you confirm.</p>
      </header>
      <Card>
        {channels.map((channel) => {
          if (!channel.live || !channel.action) return <ComingSoonRow key={channel.channel} channel={channel} />;

          if (channel.channel === "email") return <EmailChannelRow key={channel.channel} channel={channel} />;

          if (channel.channel === "x")
            return (
              <XChannelRow
                key={channel.channel}
                channel={channel}
                action={channel.action}
                productPermalink={productPermalink}
                onChange={(action) =>
                  setChannels(
                    (prev) => prev?.map((c) => (c.channel === channel.channel ? { ...c, action } : c)) ?? null,
                  )
                }
              />
            );

          // A live channel with no row of its own: render nothing rather than claim it is
          // coming soon.
          return null;
        })}
      </Card>
    </section>
  );
};

const ChannelIcon = ({ channel, className }: { channel: string; className: string }) => {
  const Icon = CHANNEL_ICONS[channel];
  return Icon ? <Icon className={className} /> : null;
};

const ComingSoonRow = ({ channel }: { channel: MarketingChannel }) => (
  <CardContent aria-disabled="true" className="text-muted">
    <div className="flex items-center gap-3">
      <ChannelIcon channel={channel.channel} className="size-6" />
      <span className="font-semibold">{channel.label}</span>
      <Pill size="small">Coming soon</Pill>
    </div>
    <Button disabled>Post on {channel.label}</Button>
  </CardContent>
);

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
          <span>{channel.blocked_reason}</span>
        </Alert>
      ) : channel.declined ? (
        <Alert role="status">
          <span>You deleted the launch email for this product, so we won&apos;t create another one.</span>
        </Alert>
      ) : draft ? (
        <>
          <span>{EMAIL_DRAFT_SUMMARY[draft.state](draft.subject)}</span>
          {counts && draft.state === "draft" ? (
            <small className="text-muted">
              {counts.customers} past {counts.customers === 1 ? "customer" : "customers"} and {counts.followers}{" "}
              {counts.followers === 1 ? "follower" : "followers"} would get it ({counts.total} people), leaving out
              everyone who already bought this product.
            </small>
          ) : null}
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

const XChannelRow = ({
  channel,
  action,
  productPermalink,
  onChange,
}: {
  channel: MarketingChannel;
  action: MarketingAction;
  productPermalink: string;
  onChange: (action: MarketingAction) => void;
}) => {
  const [copy, setCopy] = React.useState(action.copy);
  const [confirming, setConfirming] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [intentUrl, setIntentUrl] = React.useState<string | undefined>(channel.intent_url);
  const edited = copy !== action.copy;
  const terminal = action.status === "posted" || action.status === "failed" || action.status === "cancelled";

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setBusy(false);
  };

  const confirmAndPost = () =>
    run(async () => {
      const approved = await approveMarketingAction(productPermalink, action.id, edited ? copy : undefined);
      onChange(approved);
      const result = await executeMarketingAction(productPermalink, action.id);
      setIntentUrl(result.intent_url);
      onChange(result.action);
      setConfirming(false);
      if (result.action.status === "posted") showAlert("Posted on X!", "success");
    });

  return (
    <CardContent details className="grid gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-3">
          <ChannelIcon channel="x" className="size-6" />
          <span className="font-semibold">{channel.label}</span>
          {channel.connected && channel.handle ? (
            <span className="text-muted">posting as @{channel.handle}</span>
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

      {action.status === "posted" ? (
        <Alert role="status" variant="success">
          <div className="flex flex-col justify-between gap-2 sm:flex-row">
            <span>Your launch post is live.</span>
            {action.external_url ? (
              <a href={action.external_url} target="_blank" rel="noreferrer">
                View post on X
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
            <TwitterShareButton url={action.link_url ?? ""} text={action.copy} />
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
              onChange={(e) => setCopy(e.target.value)}
              maxLength={255}
              rows={3}
            />
            <small className="text-muted">
              Your tagged link{action.link_url ? ` (${action.link_url})` : ""} is added below the text so you can see
              which sales came from this post.
            </small>
          </fieldset>

          {channel.connected ? (
            <div className="flex flex-wrap gap-2">
              <Button color="primary" disabled={busy || copy.trim() === ""} onClick={() => setConfirming(true)}>
                Post on X
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
            <Alert role="status">
              <div className="flex flex-col justify-between gap-2 sm:flex-row">
                <span>Connect your X account to let Gumroad post this for you.</span>
                <div className="flex flex-wrap gap-2">
                  <NavigationButton color="primary" href={channel.connect_path}>
                    Connect X
                  </NavigationButton>
                  {intentUrl ? <TwitterShareButton url={action.link_url ?? ""} text={copy} /> : null}
                </div>
              </div>
            </Alert>
          )}
        </>
      ) : null}

      {confirming ? (
        <Modal
          open
          onClose={() => setConfirming(false)}
          title="Post on X?"
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
