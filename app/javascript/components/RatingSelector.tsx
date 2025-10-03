import * as React from "react";

import { Icon } from "$app/components/Icons";

type Props = {
  currentRating: null | number;
  onChangeCurrentRating: (newRating: number) => void;
  disabled?: boolean;
};
export const RatingSelector = ({ currentRating, onChangeCurrentRating, disabled = false }: Props) => {
  const [hoveredRating, setHoveredRating] = React.useState<null | number>(null);

  return (
    <div className="flex shrink-0 items-center gap-1" role="radiogroup" aria-label="Your rating:">
      {[1, 2, 3, 4, 5].map((rating) => (
        <Icon
          key={rating}
          aria-label={`${rating} ${rating === 1 ? "star" : "stars"}`}
          aria-checked={currentRating === rating}
          name={
            (currentRating && currentRating >= rating) || (hoveredRating && hoveredRating >= rating)
              ? "solid-star"
              : "outline-star"
          }
          role="radio"
          inert={disabled}
          onMouseOver={() => setHoveredRating(rating)}
          onMouseOut={() => setHoveredRating(null)}
          onClick={() => onChangeCurrentRating(rating)}
        />
      ))}
    </div>
  );
};
