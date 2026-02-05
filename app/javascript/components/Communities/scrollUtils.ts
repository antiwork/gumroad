// Utility function for scrolling to specific elements in the chat
export const scrollTo = (
  to:
    | { target: "top" }
    | { target: "bottom" }
    | { target: "unread-separator" }
    | { target: "message"; messageId: string; position?: ScrollLogicalPosition | undefined },
) => {
  const id =
    to.target === "top"
      ? "top"
      : to.target === "bottom"
        ? "bottom"
        : to.target === "unread-separator"
          ? "unread-separator"
          : `message-${to.messageId}`;
  const el = document.querySelector(`[data-id="${id}"]`);
  const position: ScrollLogicalPosition = to.target === "message" ? (to.position ?? "center") : "center";
  el?.scrollIntoView({ behavior: "auto", block: position });
};
