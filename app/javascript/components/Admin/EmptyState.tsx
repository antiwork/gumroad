import React from "react";

type Props = {
  message: string;
};

const EmptyState = ({ message }: Props) => (
  <div className="placeholder">
    <h2 id="empty-message">{message}</h2>
  </div>
);

export default EmptyState;
