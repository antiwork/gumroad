import { Image } from "@boxicons/react";
import * as React from "react";

import { TableCell } from "$app/components/ui/Table";

export const ProductIconCell = ({
  href,
  thumbnail,
  placeholder = <Image pack="filled" className="size-5" />,
}: {
  href: string;
  thumbnail: string | null;
  placeholder?: React.ReactNode;
}) => (
  <TableCell hideLabel className="text-center text-xl lg:w-20 lg:min-w-20 lg:border-r lg:border-border lg:p-0">
    <a href={href}>
      {thumbnail ? (
        <div className="lg:aspect-square lg:overflow-hidden">
          <img className="max-w-20 lg:size-full lg:object-cover" role="presentation" src={thumbnail} />
        </div>
      ) : (
        placeholder
      )}
    </a>
  </TableCell>
);
