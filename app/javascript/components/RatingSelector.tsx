import { Star } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Radio } from "$app/components/ui/Radio";

type Props = {
  currentRating: null | number;
  onChangeCurrentRating: (newRating: number, event: React.ChangeEvent<HTMLInputElement>) => void;
  disabled?: boolean;
};
export const RatingSelector = ({ currentRating, onChangeCurrentRating, disabled = false }: Props) => {
  const [hoveredRating, setHoveredRating] = React.useState<null | number>(null);
  const name = React.useId();

  return (
    <div className="flex shrink-0 items-center" role="radiogroup" aria-label="Your rating:">
      {[1, 2, 3, 4, 5].map((rating) => {
        const filled =
          (currentRating != null && currentRating >= rating) || (hoveredRating != null && hoveredRating >= rating);
        return (
          <label
            key={rating}
            className={classNames(
              "relative inline-flex rounded-sm has-focus-visible:outline-2 has-focus-visible:outline-offset-2",
              disabled ? "opacity-30" : "cursor-pointer",
            )}
            onMouseOver={disabled ? undefined : () => setHoveredRating(rating)}
            onMouseOut={() => setHoveredRating(null)}
          >
            <Radio
              wrapperClassName="absolute inset-0 [&>span]:hidden"
              className="size-full border-0 bg-transparent checked:bg-transparent focus:outline-none"
              name={name}
              value={rating}
              aria-label={`${rating} ${rating === 1 ? "star" : "stars"}`}
              checked={currentRating === rating}
              disabled={disabled}
              onChange={(event) => onChangeCurrentRating(rating, event)}
            />
            <Star {...(filled ? { pack: "filled" } : {})} className="size-5" />
          </label>
        );
      })}
    </div>
  );
};
