import * as React from "react";

import { cast } from "$app/utils/cast";
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

const MAX_ATTACHMENTS = 3;
const MAX_ATTACHMENT_BYTES = 3 * 1024 * 1024;
const MAX_TOTAL_ATTACHMENT_BYTES = 6 * 1024 * 1024;
const ACCEPTED_ATTACHMENT_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

// The message is kept in localStorage so closing the modal or navigating away
// from the Help Center cannot throw away text the user already wrote.
const DRAFT_STORAGE_KEY = "gumroad:help-center:contact-draft";

const readDraft = () => {
  if (typeof window === "undefined") return "";
  try {
    return window.localStorage.getItem(DRAFT_STORAGE_KEY) ?? "";
  } catch {
    // Storage can be unavailable (private mode, blocked cookies) — a lost draft
    // is not worth failing the form over.
    return "";
  }
};

const writeDraft = (message: string) => {
  try {
    if (message) window.localStorage.setItem(DRAFT_STORAGE_KEY, message);
    else window.localStorage.removeItem(DRAFT_STORAGE_KEY);
  } catch {
    // Ignore: see readDraft.
  }
};

const formatBytes = (bytes: number) => (bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`);

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
  const [message, setMessage] = React.useState(readDraft);
  const [files, setFiles] = React.useState<File[]>([]);
  // Honeypot field: invisible to humans, bots tend to fill it. The server
  // silently drops submissions where it is present.
  const [website, setWebsite] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);
  const [submitted, setSubmitted] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => writeDraft(message), [message]);

  const addFiles = (incoming: File[]) => {
    setError(null);
    const images = incoming.filter((file) => ACCEPTED_ATTACHMENT_TYPES.includes(file.type));
    if (images.length < incoming.length) {
      setError("Screenshots must be PNG, JPG, GIF or WEBP images.");
      return;
    }
    const next = [...files, ...images];
    if (next.length > MAX_ATTACHMENTS) {
      setError(`Please attach at most ${MAX_ATTACHMENTS} images.`);
      return;
    }
    if (images.some((file) => file.size > MAX_ATTACHMENT_BYTES)) {
      setError(`Each image must be smaller than ${formatBytes(MAX_ATTACHMENT_BYTES)}.`);
      return;
    }
    if (next.reduce((total, file) => total + file.size, 0) > MAX_TOTAL_ATTACHMENT_BYTES) {
      setError(`Attachments must total less than ${formatBytes(MAX_TOTAL_ATTACHMENT_BYTES)}.`);
      return;
    }
    setFiles(next);
  };

  // A screenshot pasted into the textarea arrives as a clipboard file, not as
  // text — pick it up as an attachment instead of silently dropping it.
  const handlePaste = (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const pasted = Array.from(e.clipboardData.files).filter((file) => file.type.startsWith("image/"));
    if (pasted.length === 0) return;
    e.preventDefault();
    addFiles(pasted);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (message.trim().length < MIN_MESSAGE_LENGTH) {
      setError(`Please tell us a bit more so we can help (at least ${MIN_MESSAGE_LENGTH} characters).`);
      return;
    }

    setSubmitting(true);
    try {
      const data = new FormData();
      data.append("email", email);
      data.append("category", category);
      data.append("message", message);
      data.append("website", website);
      data.append("referrer_path", referrerPath ?? (typeof window === "undefined" ? "" : window.location.pathname));
      files.forEach((file) => data.append("attachments[]", file));

      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.help_center_contact_path(),
        data,
      });
      const json = cast<{ success: true } | { success: false; error: string }>(await response.json());
      if (json.success) {
        setSubmitted(true);
        setMessage("");
        setFiles([]);
        writeDraft("");
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
              onPaste={handlePaste}
              placeholder="Tell us what's going on — include any order or product details that might help."
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-attachments`}>Screenshots (optional)</Label>
            <Input
              id={`${uid}-attachments`}
              type="file"
              multiple
              accept={ACCEPTED_ATTACHMENT_TYPES.join(",")}
              onChange={(e) => {
                addFiles(Array.from(e.target.files ?? []));
                // Reset so removing an image lets the same file be picked again.
                e.target.value = "";
              }}
            />
            <p className="text-sm text-muted">
              Up to {MAX_ATTACHMENTS} images, {formatBytes(MAX_ATTACHMENT_BYTES)} each. You can also paste a screenshot
              into the message.
            </p>
            {files.length > 0 ? (
              <ul className="flex flex-col gap-1">
                {files.map((file, index) => (
                  <li key={`${file.name}-${index}`} className="flex items-center justify-between gap-2 text-sm">
                    <span className="truncate">
                      {file.name} ({formatBytes(file.size)})
                    </span>
                    <Button type="button" size="sm" onClick={() => setFiles(files.filter((_, i) => i !== index))}>
                      Remove
                    </Button>
                  </li>
                ))}
              </ul>
            ) : null}
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
