import React from "react";

export const UserAvatar = ({
  src,
  alt,
  className = "",
  size = "medium",
}: {
  src: string;
  alt: string;
  className?: string;
  size?: "small" | "medium" | "large";
}) => {
  const sizeClasses = {
    small: "h-4 w-4",
    medium: "h-8 w-8",
    large: "h-12 w-12",
  };

  return <img src={src} alt={alt} className={`${sizeClasses[size]} rounded-full border object-cover ${className}`} />;
};
