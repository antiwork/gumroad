// Provide stub typings for removed JSON schema modules so that existing
// type-only imports continue to compile without bundling the actual JSON.
// The shape is intentionally `any` because the schemas are no longer used
// at runtime – they were only needed for static typing via `json-schema-to-ts`.
declare module "$app/json_schemas/*" {
  const schema: any;
  export default schema;
}
