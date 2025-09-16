import React, { useEffect } from "react";

import { SupportHeader } from "$app/components/server-components/support/Header";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

import { ConversationDetail } from "./ConversationDetail";
import { ConversationList } from "./ConversationList";
import { NewTicketModal } from "./NewTicketModal";

export default function SupportPortal() {
  const { searchParams } = new URL(useOriginalLocation());
  const [selectedConversationSlug, setSelectedConversationSlug] = React.useState<string | null>(searchParams.get("id"));
  const [isNewTicketOpen, setIsNewTicketOpen] = React.useState(!!searchParams.get("new_ticket"));

  useEffect(() => {
    const url = new URL(location.href);
    if (!isNewTicketOpen && url.searchParams.get("new_ticket")) {
      url.searchParams.delete("new_ticket");
      history.replaceState(null, "", url.toString());
    }
  }, [isNewTicketOpen]);

  useEffect(() => {
    const url = new URL(location.href);
    if (selectedConversationSlug) {
      url.searchParams.set("id", selectedConversationSlug);
    } else {
      url.searchParams.delete("id");
    }
    if (url.toString() !== window.location.href) history.pushState(null, "", url.toString());
  }, [selectedConversationSlug]);

  useGlobalEventListener("popstate", () => {
    const params = new URL(location.href).searchParams;
    setSelectedConversationSlug(params.get("id"));
    setIsNewTicketOpen(!!params.get("new_ticket"));
  });

  if (selectedConversationSlug != null) {
    return (
      <ConversationDetail
        conversationSlug={selectedConversationSlug}
        onBack={() => setSelectedConversationSlug(null)}
      />
    );
  }

  return (
    <>
      <div>
        <SupportHeader onOpenNewTicket={() => setIsNewTicketOpen(true)} />
        <ConversationList onSelect={setSelectedConversationSlug} onOpenNewTicket={() => setIsNewTicketOpen(true)} />
      </div>
      <NewTicketModal
        open={isNewTicketOpen}
        onClose={() => setIsNewTicketOpen(false)}
        onCreated={(slug) => {
          setIsNewTicketOpen(false);
          setSelectedConversationSlug(slug);
        }}
      />
    </>
  );
}
