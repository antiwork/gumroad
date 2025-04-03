// given fn x(a, b, c)
// const y = partiallyApplyAllButFirst(x, b, c)
// y(a)
export function partiallyApplyAllButFirst<FirstArg, RestArgs extends unknown[], Return>(
  fn: (first: FirstArg, ...rest: RestArgs) => Return,
  ...restArgs: RestArgs
): (first: FirstArg) => Return {
  return (first) => fn(first, ...restArgs);
}
