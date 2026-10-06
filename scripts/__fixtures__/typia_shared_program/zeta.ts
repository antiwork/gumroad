import typia from "typia";

// Transformed before union.ts, this creates the "zeta" type first and flips the union order.
export const checkZeta = (input: unknown) => typia.assert<{ kind: "zeta" }>(input);
