import { useConversations } from "@helperai/react";
import placeholderImage from "images/placeholders/support.png";
import React from "react";

import { Button } from "$app/components/Button";
import Placeholder from "$app/components/ui/Placeholder";

export function ConversationList({
  onSelect,
  onOpenNewTicket,
}: {
  onSelect: (slug: string) => void;
  onOpenNewTicket: () => void;
}) {
  const { data, isLoading, error } = useConversations();

  if (isLoading) return null;
  if (error) return <div>Something went wrong.</div>;

  const conversations = data?.conversations ?? [];

  if (conversations.length === 0) {
    return (
      <section className="p-4 md:p-8">
        <Placeholder>
          <figure>
            <img src={placeholderImage} />
          </figure>
          <h2>Need a hand? We're here for you.</h2>
          <p>
            Got a question about selling, payouts, or your products? Send us a message and we'll reply right here so you
            can get back to creating.
          </p>
          <Button color="accent" onClick={onOpenNewTicket}>
            Contact support
          </Button>
        </Placeholder>
      </section>
    );
  }

  return (
    <div className="p-4 md:p-8">
      <table>
        <thead>
          <tr>
            <th>Subject</th>
            <th>Last updated</th>
          </tr>
        </thead>
        <tbody>
          {conversations.map((c) => (
            <tr key={c.slug} aria-selected={false} onClick={() => onSelect(c.slug)}>
              <td className={c.isUnread ? "w-full font-bold" : "w-full"}>{c.subject}</td>
              <td className="whitespace-nowrap">
                {c.latestMessageAt
                  ? new Date(c.latestMessageAt).toLocaleDateString(undefined, {
                      day: "numeric",
                      month: "short",
                      year:
                        new Date(c.latestMessageAt).getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
                      hour: "numeric",
                      minute: "numeric",
                      hour12: true,
                    })
                  : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
