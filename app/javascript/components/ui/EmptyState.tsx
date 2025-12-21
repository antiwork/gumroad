import React from "react";

import { classNames } from "$app/utils/classNames";

type Props = {
  className?: string;
  message: string;
};

const EmptyState = ({ className, message }: Props) => (
  <div className={classNames("placeholder", className)}>
    <h2 id="empty-message">{message}</h2>
  </div>
);

export default EmptyState;
