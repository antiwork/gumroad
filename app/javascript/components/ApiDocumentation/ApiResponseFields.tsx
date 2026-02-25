import React from "react";

export type FieldDefinition = {
  name: string;
  type: string;
  description: string;
  condition?: string;
  children?: FieldDefinition[];
};

export const ApiResponseFields = ({ children }: { children: React.ReactNode }) => (
  <div className="parameters">
    <h4>Response fields:</h4>
    {children}
  </div>
);

export const ApiResponseField = ({
  name,
  type,
  description,
  condition,
  children,
}: {
  name: string;
  type: string;
  description: string;
  condition?: string;
  children?: React.ReactNode;
}) => (
  <div>
    <p>
      <strong>{name}</strong> <em>({type})</em> — {description}
      {condition ? <span className="text-muted"> ({condition})</span> : null}
    </p>
    {children ? <div className="border-l border-border pl-4">{children}</div> : null}
  </div>
);

export const renderFields = (fields: FieldDefinition[]): React.ReactNode =>
  fields.map((field) => (
    <ApiResponseField
      key={field.name}
      name={field.name}
      type={field.type}
      description={field.description}
      {...(field.condition !== undefined ? { condition: field.condition } : {})}
    >
      {field.children ? renderFields(field.children) : null}
    </ApiResponseField>
  ));
