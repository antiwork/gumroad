export function isNotNull<T>(arg: T): arg is Exclude<T, null> {
  return arg !== null;
}
