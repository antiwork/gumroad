import React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { SupportSlaMessage } from "$app/components/support/SupportSlaMessage";
import { Input } from "$app/components/ui/Input";
import { Textarea } from "$app/components/ui/Textarea";

export function NewTicketModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [subject, setSubject] = React.useState("");
  const [message, setMessage] = React.useState("");
  const formRef = React.useRef<HTMLFormElement | null>(null);

  const isFormValid = subject.trim() && message.trim();

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!isFormValid) return;

    const url = `mailto:support@gumroad.com?subject=${encodeURIComponent(subject.trim())}&body=${encodeURIComponent(message.trim())}`;
    window.location.href = url;
    showAlert("Your email client should open shortly. Send the email to complete your support request.", "success");
    onClose();
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="How can we help you today?"
      footer={
        <Button color="accent" onClick={() => formRef.current?.requestSubmit()} disabled={!isFormValid}>
          Open email
        </Button>
      }
    >
      <p>
        <SupportSlaMessage />
      </p>
      <form ref={formRef} className="space-y-4 md:w-[700px]" onSubmit={handleSubmit}>
        <label className="sr-only">Subject</label>
        <Input value={subject} placeholder="Subject" onChange={(e) => setSubject(e.target.value)} />
        <label className="sr-only">Message</label>
        <Textarea
          rows={6}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="Tell us about your issue or question..."
        />
      </form>
    </Modal>
  );
}
