// Given a collection of element, a function to compute an identifier of each element,
// and an array of identifiers in the desired orders, it will put elements into desired order.
//
// It also handles cases when an element in the collection is not present in the order array
// in one of the following elected behaviors:
// - `remove` will remove any such elements from the resulting collection
// - `putFirst` will put any such elements to the very beginning of the resulting collection
// - `putLast` will put any such elements to the very end of the resulting collection

export const reorderCollection = <Element, Id>(
  col: Element[],
  getId: (el: Element) => Id,
  desiredIdOrder: Id[],
  badElementHandling: "remove" | "putFirst" | "putLast" = "putLast",
): Element[] => {
  // ordering for unknown elements
  const handleUnknownA = badElementHandling === "putLast" ? 1 : -1;
  const handleUnknownB = badElementHandling === "putLast" ? -1 : 1;

  const badElementsToRemove: Element[] = [];

  const newCollection = col.slice().sort((a, b) => {
    const idA = getId(a);
    const idB = getId(b);

    const positionA = desiredIdOrder.indexOf(idA);
    const positionB = desiredIdOrder.indexOf(idB);

    if (positionA === -1 && positionB === -1) {
      if (badElementHandling === "remove") {
        badElementsToRemove.push(a);
        badElementsToRemove.push(b);
      }
      return 0;
    }
    if (positionA === -1) {
      if (badElementHandling === "remove") badElementsToRemove.push(a);
      return handleUnknownA;
    }
    if (positionB === -1) {
      if (badElementHandling === "remove") badElementsToRemove.push(b);
      return handleUnknownB;
    }
    return positionA - positionB;
  });

  if (badElementsToRemove.length > 0) {
    return newCollection.filter((el) => !badElementsToRemove.includes(el));
  }

  return newCollection;
};
