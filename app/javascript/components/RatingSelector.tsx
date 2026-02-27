import { Star } from "@boxicons/react";
import * as React from "react";

type Props = {
  currentRating: null | number;
  onChangeCurrentRating: (newRating: number) => void;
  disabled?: boolean;
};
export const RatingSelector = ({ currentRating, onChangeCurrentRating, disabled = false }: Props) => {
  const [hoveredRating, setHoveredRating] = React.useState<null | number>(null);

  return (
    <div className="flex shrink-0 items-center" role="radiogroup" aria-label="Your rating:">
      {[1, 2, 3, 4, 5].map((rating) => {
        const filled =
          (currentRating != null && currentRating >= rating) || (hoveredRating != null && hoveredRating >= rating);
        return (
          <span
            key={rating}
            aria-label={`${rating} ${rating === 1 ? "star" : "stars"}`}
            aria-checked={currentRating === rating}
            role="radio"
            inert={disabled}
            onMouseOver={() => setHoveredRating(rating)}
            onMouseOut={() => setHoveredRating(null)}
            onClick={() => onChangeCurrentRating(rating)}
          >
            <Star {...(filled ? { pack: "filled" } : {})} className="size-5" />
          </span>
        );
      })}
    </div>
  );
};
