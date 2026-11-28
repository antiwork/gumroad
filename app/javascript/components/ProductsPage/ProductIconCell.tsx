import { Image } from "@boxicons/react";
import * as React from "react";

import { TableCell } from "$app/components/ui/Table";

export const ProductIconCell = ({
  href,
  thumbnail,
  placeholder = <Image pack="filled" className="size-5" />,
}: {
  href?: string | undefined;
  thumbnail: string | null;
  placeholder?: React.ReactNode;
}) => {
  const content = thumbnail ? (
    <div className="max-lg:size-12 max-lg:overflow-hidden max-lg:rounded-sm lg:h-20 lg:overflow-hidden">
      <img className="size-full max-w-20 object-cover" role="presentation" src={thumbnail} />
    </div>
  ) : (
    placeholder
  );
  return (
    <TableCell
      hideLabel
      // On a phone the thumbnail sits beside the name: see `data-thumbnail` in TableCell.
      data-thumbnail
      className="text-center text-xl max-lg:flex max-lg:size-12 max-lg:shrink-0 max-lg:grow-0 max-lg:basis-12 max-lg:items-center max-lg:justify-center lg:w-20 lg:min-w-20 lg:border-r lg:border-border lg:p-0"
    >
      {href ? <a href={href}>{content}</a> : content}
    </TableCell>
  );
};
