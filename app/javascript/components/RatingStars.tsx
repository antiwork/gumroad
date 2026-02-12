import { range } from "lodash-es";
import * as React from "react";
import { Star, StarHalf } from "@boxicons/react";

export const RatingStars = ({ rating }: { rating: number }) => (
  <>
    {range(Math.round(rating)).map((key) => (
      <Star pack="filled" key={key} />
    ))}
    {rating > Math.round(rating) ? <StarHalf /> : null}
    {range(Math.floor(5 - rating)).map((key) => (
      <Star key={key} />
    ))}
  </>
);
