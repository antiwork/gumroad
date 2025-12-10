import React from "react";

import { LoadingSpinner } from "$app/components/LoadingSpinner";

export type TosViolationFlags = {
  external_id: string;
  content: string;
};

type FlagForTosViolationsContentProps = {
  isLoading: boolean;
  tosViolationFlags: TosViolationFlags[];
};

const FlagForTosViolationsContent = ({ isLoading, tosViolationFlags }: FlagForTosViolationsContentProps) => {
  if (isLoading) {
    return <LoadingSpinner />;
  }

  if (tosViolationFlags.length === 0) {
    return <p>No TOS violation flags found</p>;
  }

  return (
    <ul>
      {tosViolationFlags.map(({ external_id, content }) => (
        <li key={external_id}>{content}</li>
      ))}
    </ul>
  );
};

export default FlagForTosViolationsContent;
