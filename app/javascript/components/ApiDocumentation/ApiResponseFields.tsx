import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";
import { Details, DetailsToggle } from "$app/components/ui/Details";

export type FieldDefinition = {
  name: string;
  type: string;
  description: string;
  condition?: string;
  children?: FieldDefinition[];
};

export const ApiResponseFields = ({ children }: { children: React.ReactNode }) => (
  <Card>
    <CardContent>
      <Details>
        <DetailsToggle>
          <h4>Response fields</h4>
        </DetailsToggle>
        {children}
      </Details>
    </CardContent>
  </Card>
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
  <div className="leading-7">
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
