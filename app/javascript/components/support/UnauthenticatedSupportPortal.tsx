import React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { useRecaptcha, RecaptchaCancelledError } from "$app/components/useRecaptcha";
import { trackUserActionEvent } from "$app/data/user_action_event";

export default function UnauthenticatedSupportPortal({ recaptchaSiteKey }: { recaptchaSiteKey: string | null }) {
  const [isOpen, setIsOpen] = React.useState(false);
  const [email, setEmail] = React.useState("");
  const [subject, setSubject] = React.useState("");
  const [message, setMessage] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);
  const [errorMsg, setErrorMsg] = React.useState<string | null>(null);

  const { container: recaptchaContainer, execute } = useRecaptcha({ siteKey: recaptchaSiteKey ?? null });

  const isFormValid = React.useMemo(() => {
    const emailRegex = /^(?:[a-zA-Z0-9_'^&\/+{}=?`~!-]+(?:\.[a-zA-Z0-9_'^&\/+{}=?`~!-]+)*|"(?:[^"]|\\")+")@(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$/;
    return emailRegex.test(email.trim()) && subject.trim().length > 0 && message.trim().length > 0;
  }, [email, subject, message]);

  return (
    <>
      <main>
        <header>
          <div className="container">
            <h1>Support</h1>
            <p>Get help without signing in. We’ll email you updates.</p>
            <Button
              color="accent"
              onClick={() => {
                setIsOpen(true);
                try { trackUserActionEvent("support_unauth_modal_opened"); } catch {}
              }}
              disabled={!recaptchaSiteKey}
            >
              New ticket
            </Button>
            {!recaptchaSiteKey ? (
              <div className="mt-2 text-sm opacity-75" role="status">
                reCAPTCHA is unavailable. Please try again later.
              </div>
            ) : null}
          </div>
        </header>
      </main>
      <Modal
        open={isOpen}
        onClose={() => setIsOpen(false)}
        title="How can we help you today?"
        footer={
          <div className="flex items-center justify-end gap-2 w-full">
            {errorMsg ? (
              <div role="alert" className="danger flex-1" style={{ marginRight: "var(--spacer-3)" }}>
                {errorMsg}
                <button type="button" aria-label="Dismiss error" className="close" onClick={() => setErrorMsg(null)} />
              </div>
            ) : null}
            <Button
              color="accent"
              onClick={() => {
                const form = document.getElementById("unauth-ticket-form") as HTMLFormElement | null;
                form?.requestSubmit();
              }}
              disabled={isSubmitting || !isFormValid || !recaptchaSiteKey}
            >
              {isSubmitting ? "Sending..." : "Send message"}
            </Button>
          </div>
        }
      >
        <form
          id="unauth-ticket-form"
          className="space-y-4 md:w-[700px]"
          onSubmit={(e) => {
            e.preventDefault();
            void (async () => {
              if (!isFormValid) return;
              if (!recaptchaSiteKey) {
                setErrorMsg("Something went wrong. Please try again.");
                return;
              }
              setIsSubmitting(true);
              setErrorMsg(null);
              try {
                const token = await execute();
                const res = await fetch("/support/unauthenticated_ticket", {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  credentials: "same-origin",
                  body: JSON.stringify({ email: email.trim(), subject: subject.trim(), message: message.trim(), "g-recaptcha-response": token }),
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data?.message || "Something went wrong. Please try again.");
                setIsOpen(false);
                showAlert("Your message was sent. We’ll email you soon.", "success");
                try { trackUserActionEvent("support_unauth_ticket_submitted"); } catch {}
              } catch (err) {
                if (err instanceof RecaptchaCancelledError) return; // user dismissed captcha
                setErrorMsg("Something went wrong. Please try again.");
              } finally {
                setIsSubmitting(false);
              }
            })();
          }}
        >
          <div>
            <label className="sr-only">Email address</label>
            <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Your email address" className="w-full" required />
          </div>
          <div>
            <label className="sr-only">Subject</label>
            <input value={subject} onChange={(e) => setSubject(e.target.value)} placeholder="Subject" className="w-full" required />
          </div>
          <div>
            <label className="sr-only">Message</label>
            <textarea rows={6} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Tell us about your issue or question..." className="w-full" required />
          </div>
          <div className="mt-2" data-theme="inherit">{recaptchaContainer}</div>
        </form>
      </Modal>
    </>
  );
}


