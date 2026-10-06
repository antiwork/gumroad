import typia from "typia";

export const checkUnion = (input: unknown) => typia.assert<"alpha" | "zeta">(input);
