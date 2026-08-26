const hasFiles = (event: DragEvent): boolean => Array.from(event.dataTransfer?.types ?? []).includes("Files");

export const installFileDropNavigationGuard = (target: Document = document): (() => void) => {
  const onDragOver = (event: DragEvent) => {
    if (hasFiles(event)) event.preventDefault();
  };
  const onDrop = (event: DragEvent) => {
    if (hasFiles(event)) event.preventDefault();
  };
  target.addEventListener("dragover", onDragOver);
  target.addEventListener("drop", onDrop);
  return () => {
    target.removeEventListener("dragover", onDragOver);
    target.removeEventListener("drop", onDrop);
  };
};
