import React from "react";

import { SupportHeader } from "$app/components/server-components/support/Header";

import { NewTicketModal } from "./NewTicketModal";

export default function SupportPortal() {
  const [isNewTicketOpen, setIsNewTicketOpen] = React.useState(false);

  return (
    <>
      <SupportHeader onOpenNewTicket={() => setIsNewTicketOpen(true)} />
      <NewTicketModal open={isNewTicketOpen} onClose={() => setIsNewTicketOpen(false)} />
    </>
  );
}
