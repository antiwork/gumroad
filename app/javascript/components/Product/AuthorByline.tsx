import * as React from "react";

import { WithTooltip } from "$app/components/WithTooltip";

export const TopCreatorBadge = () => (
  <svg
    width="16"
    height="16"
    viewBox="3.5 5 17 17"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className="top-creator-badge shrink-0"
    aria-hidden="true"
    focusable="false"
  >
    <path
      d="M12.6895 14.4967C12.2571 14.7205 11.7429 14.7205 11.3105 14.4967L5.31055 11.3903C4.81285 11.1326 4.50011 10.6187 4.5 10.0582L4.5 7.41662C4.5 6.5882 5.17157 5.91662 6 5.91662L18 5.91663C18.8284 5.91663 19.5 6.5882 19.5 7.41663L19.5 10.0582C19.4999 10.6187 19.1872 11.1326 18.6895 11.3903L12.6895 14.4967Z"
      fill="#FFC900"
      stroke="black"
    />
    <circle cx="12" cy="18.8333" r="2.45" fill="#FFC900" stroke="#242423" strokeWidth="1.1" />
    <path d="M9 5.41663H10V13.4166L9 12.8974V5.41663Z" fill="black" />
    <path d="M14 5.41663H15V13.0166L14 13.4166V5.41663Z" fill="black" />
  </svg>
);

export const AuthorByline = ({
  name,
  profileUrl,
  avatarUrl,
  isTopCreator,
}: {
  name: string;
  profileUrl: string;
  avatarUrl?: string | undefined;
  isTopCreator?: boolean | undefined;
}) => (
  <a href={profileUrl} target="_blank" className="relative flex items-center gap-2" rel="noreferrer">
    {avatarUrl ? <img className="user-avatar" src={avatarUrl} /> : null}
    {name}
    {isTopCreator ? (
      <WithTooltip tip="Top creator" position="top">
        <TopCreatorBadge />
        <span className="sr-only">Top creator</span>
      </WithTooltip>
    ) : null}
  </a>
);
