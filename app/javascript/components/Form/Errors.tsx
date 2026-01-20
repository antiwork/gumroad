import React from "react";

type ErrorsProps = {
  errors: string[] | string | undefined;
  label: string;
};

const Errors = ({ errors, label }: ErrorsProps) => {
  if (typeof errors === "string") {
    errors = [errors];
  }
  return (
    errors &&
    errors.length > 0 && (
      <ul className="list-none pl-0 text-red">
        {errors.map((error, index) => (
          <li key={`${label}-${index}`}>
            {label} {error}
          </li>
        ))}
      </ul>
    )
  );
};

export default Errors;
