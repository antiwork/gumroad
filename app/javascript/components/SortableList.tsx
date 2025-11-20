import cx from "classnames";
import * as React from "react";
import { ReactSortable as Sortable, ReactSortableProps } from "react-sortablejs";

const IsBeingDraggedContext = React.createContext(false);
const useIsBeingDragged = () => React.useContext(IsBeingDraggedContext);

type Props = {
  currentOrder: string[];
  onReorder: (newIdOrder: string[]) => void;
  children: React.ReactNode;
  group?: string | undefined;
  tag?: ReactSortableProps<string>["tag"];
};
export const SortableList = ({ currentOrder, onReorder, children, group, tag = "div" }: Props) => {
  const [isBeingDragged, setIsBeingDragged] = React.useState<boolean>(false);

  return (
    <IsBeingDraggedContext.Provider value={isBeingDragged}>
      <Sortable
        group={group}
        list={currentOrder.map((id) => ({ id }))}
        setList={(items) => {
          const itemIds = items.map((i) => i.id);
          onReorder(itemIds);
        }}
        handle="[aria-grabbed]"
        tag={tag}
        scrollSensitivity={150}
        setData={(dataTransfer: DataTransfer, draggedElement: HTMLElement) => {
          const drawers = draggedElement.querySelectorAll<HTMLElement>(".drawer");
          for (const drawer of drawers) drawer.hidden = true;
          dataTransfer.setDragImage(draggedElement, 0, 0);
        }}
        onStart={() => setIsBeingDragged(true)}
        onEnd={() => setIsBeingDragged(false)}
      >
        {children}
      </Sortable>
    </IsBeingDraggedContext.Provider>
  );
};

export const ReorderingHandle = () => {
  const rowIsBeingDragged = useIsBeingDragged();
  const [ref, setRef] = React.useState<null | HTMLDivElement>(null);
  const [grabbed, setGrabbed] = React.useState(false);

  React.useEffect(() => {
    const rowElement = ref?.closest("[role=treeitem]");
    setGrabbed(rowElement?.getAttribute("draggable") === "true");
  }, [rowIsBeingDragged]);

  return <div ref={setRef} aria-grabbed={grabbed} data-drag-handle draggable />;
};

export const Drawer = ({ className, children, ...rest }: React.HTMLAttributes<HTMLDivElement>) => {
  const shouldCollapseDrawer = useIsBeingDragged();
  if (shouldCollapseDrawer) return null;

  return (
    <div className={cx("drawer", "flex flex-col gap-4", className)} {...rest}>
      {children}
    </div>
  );
};
