import { range } from "lodash-es";
import * as React from "react";

import { Icon } from "$app/components/Icons";

export const RatingStars = ({ rating }: { rating: number }) => (
  <>
    {range(Math.round(rating)).map((key) => (
      <Icon name="solid-star" key={key} />
    ))}
    {rating > Math.round(rating) ? <Icon name="half-star" /> : null}
    {range(Math.floor(5 - rating)).map((key) => (
      <Icon name="outline-star" key={key} />
    ))}
  </>
);
