import React from "react";

export const ApiResource = ({ name, id, children }: { name: string; id: string; children: React.ReactNode }) => (
  <div className="stack" id={id}>
    <div>
      <h2>{name}</h2>
    </div>
    {children}
  </div>
);
