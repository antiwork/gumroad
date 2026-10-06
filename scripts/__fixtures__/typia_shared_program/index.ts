import typia from "typia";

export const check = (input: unknown) => typia.assert<GlobalShape>(input);
