export function escapeRegExp(str: string) {
  return str.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
