import React from "react";

import { NewEmailButton } from "$app/components/EmailsPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

export const EmptyStatePlaceholder = ({
  title,
  description,
  placeholderImage,
}: {
  title: string;
  description: string;
  placeholderImage: string;
}) => (
  <Placeholder>
    <PlaceholderImage src={placeholderImage} />
    <h2>{title}</h2>
    <p>{description}</p>
    <NewEmailButton />
    <p>
      <a href="/help/article/169-how-to-send-an-update" target="_blank" rel="noreferrer">
        Learn more about emails
      </a>
    </p>
  </Placeholder>
);
