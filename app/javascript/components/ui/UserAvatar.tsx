import cx from "classnames";
import * as React from "react";

type UserAvatarProps = {
  src?: string | undefined;
  alt?: string | undefined;
  className?: string;
  style?: React.CSSProperties;
};

export const UserAvatar = ({ src, alt = "User avatar", className, style, ...props }: UserAvatarProps) => (
  <img
    className={cx("aspect-square w-5 shrink-0 rounded-full border border-border", className)}
    src={src}
    alt={alt}
    style={style}
    {...props}
  />
);
