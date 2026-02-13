import { range } from "lodash-es";
import * as React from "react";
import { Star, StarHalf } from "@boxicons/react";

export const RatingStars = ({ rating }: { rating: number }) => (
  <>
    {range(Math.round(rating)).map((key) => (
      <Star pack="filled" key={key} className="size-5" />
    ))}
    {rating > Math.round(rating) ? <StarHalf className="size-5" /> : null}
    {range(Math.floor(5 - rating)).map((key) => (
      <Star key={key} className="size-5" />
    ))}
  </>
);
