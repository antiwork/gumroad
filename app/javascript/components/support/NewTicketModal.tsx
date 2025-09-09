import { useCreateConversation, useCreateMessage } from "@helperai/react";
import React from "react";

import FileUtils from "$app/utils/file";

import { Button } from "$app/components/Button";
import { useDomains } from "$app/components/DomainSettings";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";

export function NewTicketModal({
  open,
  onClose,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (slug: string) => void;
}) {
  const { apiDomain } = useDomains();
  const { mutateAsync: createConversation } = useCreateConversation({
    onError: (error) => {
      showAlert(error.message, "error");
    },
  });
  const { mutateAsync: createMessage } = useCreateMessage({
    onError: (error) => {
      showAlert(error.message, "error");
    },
  });

  const [subject, setSubject] = React.useState("");
  const [message, setMessage] = React.useState("");
  const [attachments, setAttachments] = React.useState<File[]>([]);
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const formRef = React.useRef<HTMLFormElement | null>(null);
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="How can we help you today?"
      footer={
        <>
          <Button onClick={() => fileInputRef.current?.click()} disabled={isSubmitting}>
            <Icon name="paperclip" /> Attach files
          </Button>
          <Button
            color="accent"
            onClick={() => formRef.current?.requestSubmit()}
            disabled={isSubmitting || !subject.trim() || !message.trim()}
          >
            {isSubmitting ? "Sending..." : "Send message"}
          </Button>
        </>
      }
    >
      <form
        ref={formRef}
        className="space-y-4 md:w-[700px]"
        onSubmit={(e) => {
          e.preventDefault();
          void (async () => {
            if (!subject.trim() || !message.trim()) return;
            setIsSubmitting(true);
            try {
              const { conversationSlug } = await createConversation({ subject: subject.trim() });
              await createMessage({
                conversationSlug,
                content: message.trim(),
                attachments,
                customerInfoUrl: Routes.user_info_api_internal_helper_users_url({ host: apiDomain }),
              });
              onCreated(conversationSlug);
            } finally {
              setIsSubmitting(false);
            }
          })();
        }}
      >
        <label className="sr-only">Subject</label>
        <input value={subject} placeholder="Subject" onChange={(e) => setSubject(e.target.value)} />
        <label className="sr-only">Message</label>
        <textarea
          rows={6}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="Tell us about your issue or question..."
        />
        <input
          ref={fileInputRef}
          type="file"
          multiple
          onChange={(e) => {
            const files = Array.from(e.target.files ?? []);
            if (files.length === 0) return;
            setAttachments((prev) => [...prev, ...files]);
            e.currentTarget.value = "";
          }}
        />
        {attachments.length > 0 ? (
          <div role="list" className="rows" aria-label="Files">
            {attachments.map((file, index) => (
              <div role="listitem" key={`${file.name}-${index}`}>
                <div className="content">
                  <FileRowContent
                    name={FileUtils.getFileNameWithoutExtension(file.name)}
                    extension={FileUtils.getFileExtension(file.name).toUpperCase()}
                    externalLinkUrl={null}
                    isUploading={false}
                    details={<li>{FileUtils.getReadableFileSize(file.size)}</li>}
                  />
                </div>
                <div className="actions">
                  <Button
                    outline
                    color="danger"
                    aria-label="Remove"
                    onClick={() => setAttachments((prev) => prev.filter((_, i) => i !== index))}
                  >
                    <Icon name="trash2" />
                  </Button>
                </div>
              </div>
            ))}
          </div>
        ) : null}
      </form>
    </Modal>
  );
}
