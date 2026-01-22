import * as React from "react";

import { Icon } from "$app/components/Icons";
import { TableCell } from "$app/components/ui/Table";

export const ProductIconCell = ({
  href,
  thumbnail,
  placeholder = <Icon name="card-image-fill" />,
}: {
  href: string;
  thumbnail: string | null;
  placeholder?: React.ReactNode;
}) => (
  <TableCell hideLabel className="relative text-center text-xl lg:w-20 lg:min-w-20 lg:border-r lg:border-border">
    <a href={href}>
      {thumbnail ? (
        <img
          className="max-w-20 lg:absolute lg:inset-0 lg:h-full lg:w-full lg:object-cover"
          role="presentation"
          src={thumbnail}
        />
      ) : (
        placeholder
      )}
    </a>
  </TableCell>
);
