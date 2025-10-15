import React from "react";

type Props = {
  errors: string[] | undefined;
  label: string;
};

const Errors = ({ errors, label }: Props) =>
  errors &&
  errors.length > 0 && (
    <ul className="list-none pl-0 text-red">
      {errors.map((error, index) => (
        <li key={`${label}-${index}`}>
          {label} {error}
        </li>
      ))}
    </ul>
  );

export default Errors;
