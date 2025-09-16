import React from "react";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { useRecaptcha, RecaptchaCancelledError } from "$app/components/useRecaptcha";

export function UnauthenticatedNewTicketModal({
  open,
  onClose,
  onCreated,
  recaptchaSiteKey,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: () => void;
  recaptchaSiteKey: string | null;
}) {
  const { container: recaptchaContainer, execute: executeRecaptcha } = useRecaptcha({
    siteKey: recaptchaSiteKey,
  });

  const [email, setEmail] = React.useState("");
  const [subject, setSubject] = React.useState("");
  const [message, setMessage] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const formRef = React.useRef<HTMLFormElement | null>(null);

  const isFormValid = email.trim() && subject.trim() && message.trim();

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!isFormValid) return;

    setIsSubmitting(true);
    try {
      const recaptchaResponse = recaptchaSiteKey ? await executeRecaptcha() : null;

      const response = await request({
        method: "POST",
        url: "/support/create_unauthenticated_ticket",
        accept: "json",
        data: {
          email: email.trim(),
          subject: subject.trim(),
          message: message.trim(),
          "g-recaptcha-response": recaptchaResponse,
        },
      });

      if (!response.ok) throw new ResponseError("Failed to create support ticket");

      showAlert("Your support ticket has been created successfully! We'll get back to you via email.", "success");
      onCreated();
      setEmail("");
      setSubject("");
      setMessage("");
    } catch (error) {
      if (error instanceof RecaptchaCancelledError) return;
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="How can we help you today?"
      footer={
        <Button
          color="accent"
          onClick={() => {
            formRef.current?.requestSubmit();
          }}
          disabled={isSubmitting || !isFormValid}
        >
          {isSubmitting ? "Sending..." : "Send message"}
        </Button>
      }
    >
      <form
        ref={formRef}
        className="space-y-4 md:w-[700px]"
        onSubmit={(e) => {
          void handleSubmit(e);
        }}
      >
        <div>
          <label className="sr-only">Email address</label>
          <input
            type="email"
            value={email}
            placeholder="Your email address"
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </div>
        <div>
          <label className="sr-only">Subject</label>
          <input value={subject} placeholder="Subject" onChange={(e) => setSubject(e.target.value)} required />
        </div>
        <div>
          <label className="sr-only">Message</label>
          <textarea
            rows={6}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="Tell us about your issue or question..."
            required
          />
        </div>
        {recaptchaContainer}
      </form>
    </Modal>
  );
}
