export const toggleItem = <T>(set: Set<T>, elt: T): void => void (set.has(elt) ? set.delete(elt) : set.add(elt));
