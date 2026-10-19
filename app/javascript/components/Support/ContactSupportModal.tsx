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

// The message text (not the screenshots) is kept in sessionStorage so closing the
// modal, navigating or reloading the tab cannot throw it away. sessionStorage
// ends with the tab, so a shared browser never shows it to the next visitor, and
// the key keeps signed-in accounts and anonymous visitors apart within a tab.
const DRAFT_KEY_PREFIX = "gumroad:help-center:contact-draft:";
const draftStorageKey = (userId: string | null) => `${DRAFT_KEY_PREFIX}${userId ?? "anonymous"}`;

const readDraft = (key: string) => {
  if (typeof window === "undefined") return "";
  try {
    return window.sessionStorage.getItem(key) ?? "";
  } catch {
    // Storage can be unavailable (private mode, blocked cookies) — a lost draft
    // is not worth failing the form over.
    return "";
  }
};

const writeDraft = (key: string, message: string) => {
  try {
    if (message) window.sessionStorage.setItem(key, message);
    else window.sessionStorage.removeItem(key);
  } catch {
    // Ignore: see readDraft.
  }
};

// Drafts used to live in localStorage, where the anonymous one outlived the
// visitor who wrote it.
const discardLocalStorageDrafts = () => {
  try {
    const keys = Array.from({ length: window.localStorage.length }, (_, index) => window.localStorage.key(index));
    for (const key of keys) if (key?.startsWith(DRAFT_KEY_PREFIX)) window.localStorage.removeItem(key);
  } catch {
    // Ignore: see readDraft.
  }
};

const formatBytes = (bytes: number) =>
  bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`;

// Contact form that submits into the Gumroad support pipeline. It lives in a
// modal so any page can offer a "Contact support" affordance later (the Help
// Center is the first mount) — render <ContactSupportModal> with your own
// trigger and pass the page's path as `referrerPath` so support can see where
// the user came from.
type ContactSupportModalProps = {
  open: boolean;
  onClose: () => void;
  referrerPath?: string;
};

export const ContactSupportModal = (props: ContactSupportModalProps) => {
  const loggedInUser = useLoggedInUser();
  React.useEffect(discardLocalStorageDrafts, []);
  // Remount on an account change, so nothing typed or attached under one
  // identity is shown to, or saved under the draft key of, the next one.
  return <ContactSupportForm key={loggedInUser?.id ?? "anonymous"} {...props} />;
};

const ContactSupportForm = ({ open, onClose, referrerPath }: ContactSupportModalProps) => {
  const loggedInUser = useLoggedInUser();
  const uid = React.useId();
  const draftKey = draftStorageKey(loggedInUser?.id ?? null);
  const [email, setEmail] = React.useState(loggedInUser?.email ?? "");
  const [category, setCategory] = React.useState("");
  const [message, setMessage] = React.useState(() => readDraft(draftKey));
  const [files, setFiles] = React.useState<File[]>([]);
  const fileInputRef = React.useRef<HTMLInputElement>(null);
  // Honeypot field: invisible to humans, bots tend to fill it. The server
  // silently drops submissions where it is present.
  const [website, setWebsite] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);
  const [submitted, setSubmitted] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => writeDraft(draftKey, message), [draftKey, message]);

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
  // text — pick it up as an attachment instead of silently dropping it. The paste
  // itself goes ahead, so any text copied alongside the image still lands.
  const handlePaste = (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const pasted = Array.from(e.clipboardData.files).filter((file) => file.type.startsWith("image/"));
    if (pasted.length > 0) addFiles(pasted);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (message.trim().length < MIN_MESSAGE_LENGTH) {
      setError(`Please tell us a bit more so we can help (at least ${MIN_MESSAGE_LENGTH} characters).`);
      return;
    }

    // The fields stay locked until this settles: success clears the draft, which
    // would also drop anything typed in the meantime.
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
        writeDraft(draftKey, "");
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
              disabled={submitting}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-category`}>What do you need help with?</Label>
            <Select
              id={`${uid}-category`}
              required
              disabled={submitting}
              value={category}
              onChange={(e) => setCategory(e.target.value)}
            >
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
              disabled={submitting}
              rows={6}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              onPaste={handlePaste}
              placeholder="Tell us what's going on — include any order or product details that might help."
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor={`${uid}-attachments`}>Screenshots (optional)</Label>
            {/* The native control would keep saying "No file chosen" after the reset below, so it stays hidden and
                the list is the only record of what will be sent. Input's own w-full, padding and border outrank
                sr-only, so they are replaced here; otherwise the hidden box widens the dialog. */}
            <Input
              ref={fileInputRef}
              id={`${uid}-attachments`}
              type="file"
              multiple
              className="sr-only w-px border-0 p-0"
              tabIndex={-1}
              disabled={submitting}
              accept={ACCEPTED_ATTACHMENT_TYPES.join(",")}
              onChange={(e) => {
                addFiles(Array.from(e.target.files ?? []));
                // Reset so removing an image lets the same file be picked again.
                e.target.value = "";
              }}
            />
            <Button
              className="self-start"
              disabled={submitting}
              aria-describedby={`${uid}-attachments-hint`}
              onClick={() => fileInputRef.current?.click()}
            >
              Add screenshots
            </Button>
            <p id={`${uid}-attachments-hint`} className="text-sm text-muted">
              Up to {MAX_ATTACHMENTS} images, {formatBytes(MAX_ATTACHMENT_BYTES)} each. You can also paste a screenshot
              into the message.
            </p>
            {files.length > 0 ? (
              <ul className="flex flex-col gap-1">
                {files.map((file, index) => (
                  <li key={`${file.name}-${index}`} className="flex items-center justify-between gap-2 text-sm">
                    {/* w-0 keeps a long name from widening the dialog past a phone screen; flex-1 then fills the row. */}
                    <span className="flex w-0 flex-1 gap-1">
                      <span className="truncate">{file.name}</span>{" "}
                      <span className="shrink-0">({formatBytes(file.size)})</span>
                    </span>
                    <Button
                      type="button"
                      size="sm"
                      className="shrink-0 whitespace-nowrap"
                      disabled={submitting}
                      onClick={() => setFiles(files.filter((_, i) => i !== index))}
                    >
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
