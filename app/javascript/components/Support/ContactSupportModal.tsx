import * as React from "react";
import typia from "typia";

import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Textarea } from "$app/components/ui/Textarea";

export const SUPPORT_EMAIL = "support@gumroad.com";

const CATEGORIES = ["account", "payouts", "purchases & refunds", "technical issue", "other"] as const;

const MIN_MESSAGE_LENGTH = 10;

// Contact form that submits into the Gumroad support pipeline. It lives in a
// modal so any page can offer a "Contact support" affordance later (the Help
// Center is the first mount) — render <ContactSupportModal> with your own
// trigger and pass the page's path as `referrerPath` so support can see where
// the user came from.
export const ContactSupportModal = ({
  open,
  onClose,
  referrerPath,
}: {
  open: boolean;
  onClose: () => void;
  referrerPath?: string;
}) => {
  const loggedInUser = useLoggedInUser();
  const uid = React.useId();
  const [email, setEmail] = React.useState(loggedInUser?.email ?? "");
  const [category, setCategory] = React.useState("");
  const [message, setMessage] = React.useState("");
  // Honeypot field: invisible to humans, bots tend to fill it. The server
  // silently drops submissions where it is present.
  const [website, setWebsite] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);
  const [submitted, setSubmitted] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (message.trim().length < MIN_MESSAGE_LENGTH) {
      setError(`Please tell us a bit more so we can help (at least ${MIN_MESSAGE_LENGTH} characters).`);
      return;
    }

    setSubmitting(true);
    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.help_center_contact_path(),
        data: {
          email,
          category,
          message,
          website,
          referrer_path: referrerPath ?? (typeof window === "undefined" ? "" : window.location.pathname),
        },
      });
      const json = typia.assert<{ success: true } | { success: false; error: string }>(await response.json());
      if (json.success) {
        setSubmitted(true);
      } else {
        setError(json.error);
      }
    } catch (e) {
      assertResponseError(e);
      setError(e.message);
    } finally {
      setSubmitting(false);
    }
  };

  const handleClose = () => {
    setSubmitted(false);
    setError(null);
    onClose();
  };

  return (
    <Modal open={open} onClose={handleClose} title="Contact support">
      {submitted ? (
        <div className="flex flex-col gap-4">
          <p>
            <strong>Message sent!</strong> Our support team will get back to you at <strong>{email}</strong>, usually
            within 24 hours.
          </p>
          <Button onClick={handleClose}>Close</Button>
        </div>
      ) : (
        <form className="flex flex-col gap-4" onSubmit={(e) => void handleSubmit(e)}>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-email`}>Your email</Label>
            <Input
              id={`${uid}-email`}
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-category`}>What do you need help with?</Label>
            <Select id={`${uid}-category`} required value={category} onChange={(e) => setCategory(e.target.value)}>
              <option value="" disabled>
                Select a category
              </option>
              {CATEGORIES.map((c) => (
                <option key={c} value={c}>
                  {c.charAt(0).toUpperCase() + c.slice(1)}
                </option>
              ))}
            </Select>
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-message`}>Message</Label>
            <Textarea
              id={`${uid}-message`}
              required
              rows={6}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="Tell us what's going on — include any order or product details that might help."
            />
          </div>
          {/* Honeypot — hidden from real users (and from assistive tech). */}
          <input
            type="text"
            name="website"
            value={website}
            onChange={(e) => setWebsite(e.target.value)}
            tabIndex={-1}
            autoComplete="off"
            aria-hidden
            className="hidden"
          />
          {error ? (
            <p role="alert" className="text-danger">
              {error}
            </p>
          ) : null}
          <Button color="accent" type="submit" disabled={submitting}>
            {submitting ? "Sending..." : "Send message"}
          </Button>
          <p className="text-sm text-muted">
            Prefer email? Reach us at <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>
          </p>
        </form>
      )}
    </Modal>
  );
};
