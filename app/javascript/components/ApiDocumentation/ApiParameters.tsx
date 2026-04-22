import React from "react";

export const ApiParameters = ({ children }: { children: React.ReactNode }) => (
  <div>
    <h4>Parameters:</h4>
    {children}
  </div>
);

export const ApiParameter = ({ name, description }: { name: string; description?: React.ReactNode }) => (
  <p>
    <strong>{name}</strong> {description}
  </p>
);
