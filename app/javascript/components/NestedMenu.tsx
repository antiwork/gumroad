import * as React from "react";
import { CSSProperties } from "react";

import { isOpenTuple } from "$app/utils/array";
import { assert } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { useDropdownPosition } from "$app/components/Popover";
import { Sheet } from "$app/components/ui/Sheet";
import { useIsOnTouchDevice } from "$app/components/useIsOnTouchDevice";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";
import { useWindowDimensions } from "$app/components/useWindowDimensions";

type MenuItemKey = string;
export type MenuItem = {
  key: MenuItemKey;
  parentKey?: MenuItemKey;
  label: string;
  href?: string;
  css?: CSSProperties;
  image?: string;
};

type NestedMenuType = "menubar" | "menu";
type SelectItemHandler = (item: MenuItem, clickEvent: React.MouseEvent<HTMLAnchorElement>) => void;
type NestedMenuProps = {
  type: NestedMenuType;
  items: MenuItem[];
  selectedItemKey?: MenuItemKey | undefined;
  onSelectItem?: SelectItemHandler;
  moreLabel?: string;
  buttonLabel?: string;
  footer?: React.ReactNode;
  menuTop?: string;
} & React.AriaAttributes;

export const NestedMenu = ({
  type,
  items,
  selectedItemKey,
  onSelectItem,
  moreLabel,
  buttonLabel,
  footer,
  menuTop,
  ...extraAriaAttrs
}: NestedMenuProps) => {
  const itemsMap = React.useMemo(() => {
    const iMap = new Map<MenuItemKey, MenuItemWithChildren>(
      items.map((i) => [i.key, { ...i, children: [], parent: null }]),
    );
    for (const i of iMap.values()) {
      if (!i.parentKey) continue;
      const parent = iMap.get(i.parentKey);
      if (!parent) continue;
      i.parent = parent;
      parent.children.push(i);
    }
    return iMap;
  }, [items]);

  const topLevelMenuItems = React.useMemo(() => [...itemsMap.values()].filter((item) => !item.parent), [itemsMap]);
  const selectedItem = (selectedItemKey && itemsMap.get(selectedItemKey)) || null;
  const menuContent = React.useMemo<MenuContextValue>(
    () => ({
      selectedItem,
      topLevelMenuItems,
      onSelectItem: (menuItem, e) => {
        if (menuItem.href && (e.ctrlKey || e.shiftKey)) return;
        e.preventDefault();
        onSelectItem?.(menuItem, e);
      },
    }),
    [selectedItem, topLevelMenuItems],
  );

  return (
    <MenuContext.Provider value={menuContent}>
      <div>
        {type === "menubar" ? (
          <Menubar moreLabel={moreLabel} {...extraAriaAttrs} />
        ) : (
          <OverlayMenu buttonLabel={buttonLabel} footer={footer} menuTop={menuTop} {...extraAriaAttrs} />
        )}
      </div>
    </MenuContext.Provider>
  );
};

type MenuItemWithChildren = MenuItem & { children: MenuItemWithChildren[]; parent: MenuItemWithChildren | null };
type MenuContextValue = {
  onSelectItem?: SelectItemHandler;
  selectedItem: MenuItemWithChildren | null;
  topLevelMenuItems: MenuItemWithChildren[];
};

const MenuContext = React.createContext<MenuContextValue | null>(null);

const useMenuContext = () => {
  const value = React.useContext(MenuContext);
  assert(value != null, "Cannot read menu context, make sure MenuContextProvider is used");
  return value;
};

const getRootItem = (item: MenuItemWithChildren | null) => {
  if (!item) return null;
  let curr = item;
  while (curr.parent) curr = curr.parent;
  return curr;
};

const Menubar = ({ moreLabel, ...extraAriaAttrs }: { moreLabel?: string | undefined } & React.AriaAttributes) => {
  const { selectedItem, topLevelMenuItems } = useMenuContext();
  const parentRef = React.useRef<HTMLDivElement>(null);
  const [highlightedMenubarItem, setHighlightedMenubarItem] = React.useState(() => getRootItem(selectedItem));
  const resetHighlightedMenubarItem = () => setHighlightedMenubarItem(getRootItem(selectedItem));
  React.useEffect(resetHighlightedMenubarItem, [selectedItem]);
  useOnOutsideClick([parentRef.current], resetHighlightedMenubarItem);

  const itemsUnderMore = useArrangeMenubarItems(parentRef, topLevelMenuItems);
  const menubarItems = itemsUnderMore?.length ? topLevelMenuItems.slice(0, -itemsUnderMore.length) : topLevelMenuItems;
  const moreMenuItem = { key: "more#key", label: "More", children: itemsUnderMore ?? [], parent: null };
  return (
    <div
      ref={parentRef}
      role="menubar"
      className={classNames("grid auto-cols-max grid-flow-col items-center", {
        "overflow-x-hidden": itemsUnderMore === null,
      })}
      {...extraAriaAttrs}
    >
      {menubarItems.map((menuItem) => (
        <MenubarItem
          key={menuItem.key}
          menuItem={menuItem}
          isHighlighted={highlightedMenubarItem === menuItem}
          onHighlightIn={() => setHighlightedMenubarItem(menuItem)}
          onHighlightOut={resetHighlightedMenubarItem}
          showAllItem
        />
      ))}
      {itemsUnderMore === null || itemsUnderMore.length > 0 ? (
        <MenubarItem
          menuItem={moreMenuItem}
          isHighlighted={
            highlightedMenubarItem?.key === moreMenuItem.key ||
            (highlightedMenubarItem !== null && !!itemsUnderMore?.includes(highlightedMenubarItem))
          }
          onHighlightIn={() => setHighlightedMenubarItem(moreMenuItem)}
          onHighlightOut={resetHighlightedMenubarItem}
          showExpandableIcon
          aria-label={moreLabel}
        />
      ) : null}
    </div>
  );
};

const useArrangeMenubarItems = (
  parentRef: React.RefObject<HTMLDivElement>,
  topLevelMenuItems: MenuItemWithChildren[],
) => {
  const currentSeller = useCurrentSeller();
  const initialItemsUnderMore = currentSeller ? topLevelMenuItems.slice(6) : null;
  const [itemsUnderMore, setItemsUnderMore] = React.useState<MenuItemWithChildren[] | null>(initialItemsUnderMore);

  const dimensions = useWindowDimensions(250);
  React.useEffect(() => setItemsUnderMore(initialItemsUnderMore), [dimensions]);

  React.useEffect(() => {
    if (!parentRef.current || itemsUnderMore != null) return;

    const items = [...parentRef.current.children].reverse();
    assert(isOpenTuple(items, 1), "Menubar is empty");
    const moreItemWidth = items[0].getBoundingClientRect().width;
    const maximumRightCoordinate = parentRef.current.getBoundingClientRect().right - moreItemWidth;
    for (const [i, item] of items.slice(1).entries()) {
      if (item.getBoundingClientRect().right <= maximumRightCoordinate) {
        setItemsUnderMore(i === 0 ? [] : topLevelMenuItems.slice(-i));
        return;
      }
    }
    setItemsUnderMore(topLevelMenuItems);
  }, [itemsUnderMore]);

  return itemsUnderMore;
};

const MenubarItem = ({
  menuItem,
  isHighlighted,
  onHighlightIn,
  onHighlightOut,
  showAllItem,
  showExpandableIcon,
  ...extraAriaAttrs
}: {
  menuItem: MenuItemWithChildren;
  isHighlighted: boolean;
  onHighlightIn: () => void;
  onHighlightOut: () => void;
  showAllItem?: boolean;
  showExpandableIcon?: boolean;
} & React.AriaAttributes) => {
  const isOnTouchDevice = useIsOnTouchDevice();
  const { onSelectItem, selectedItem } = useMenuContext();
  const [menuOpen, setMenuOpen] = React.useState(false);
  React.useEffect(() => setMenuOpen(false), [selectedItem]);
  React.useEffect(() => {
    if (!isHighlighted) {
      setMenuOpen(false);
      if (closeTimeoutRef.current) clearTimeout(closeTimeoutRef.current);
    }
  }, [isHighlighted]);
  const ref = React.useRef<HTMLDivElement>(null);
  const uid = React.useId();
  const dropdownPosition = useDropdownPosition(ref);

  const handleToggleMenu = (open: boolean) => {
    if (closeTimeoutRef.current) clearTimeout(closeTimeoutRef.current);
    if (open) {
      onHighlightIn();
      if (menuItem.children.length > 0) setMenuOpen(true);
    } else {
      if (isHighlighted) onHighlightOut();
      setMenuOpen(false);
    }
  };

  const closeTimeoutRef = React.useRef<ReturnType<typeof setTimeout>>();

  const closeAfterDelay = () => {
    closeTimeoutRef.current = setTimeout(() => handleToggleMenu(false), 400);
  };

  const hasChildren = menuItem.children.length > 0;

  const menuItemAnchor = (
    <a
      href={menuItem.href ?? "#"}
      className={classNames(
        "button",
        "rounded-full! px-3! py-2! align-middle aria-[current]:bg-background aria-[current]:text-foreground",
        showExpandableIcon ? "relative cursor-pointer" : "",
        hasChildren ? "aria-[current=true]:hover:shadow!" : "hover:shadow!",
        { "border-transparent! bg-transparent! text-inherit!": !isHighlighted },
        { expandable: showExpandableIcon },
      )}
      role="menuitem"
      aria-current={isHighlighted}
      aria-haspopup={hasChildren ? "menu" : undefined}
      aria-expanded={hasChildren ? menuOpen : undefined}
      aria-controls={hasChildren ? uid : undefined}
      {...extraAriaAttrs}
      onClick={(e) => {
        if (hasChildren) {
          if (isOnTouchDevice) e.preventDefault();
          else onSelectItem?.(menuItem, e);
        } else {
          onHighlightIn();
          onSelectItem?.(menuItem, e);
        }
      }}
    >
      {menuItem.label}
      {showExpandableIcon ? <Icon name="outline-cheveron-down" className="float-right" /> : null}
    </a>
  );

  return (
    <div
      ref={hasChildren ? ref : undefined}
      className={hasChildren ? classNames("popover", { expanded: menuOpen }) : undefined}
      onMouseEnter={() => handleToggleMenu(true)}
      onMouseLeave={hasChildren ? closeAfterDelay : () => handleToggleMenu(false)}
    >
      {menuItemAnchor}
      {hasChildren ? (
        <div className="dropdown" hidden={!menuOpen} style={dropdownPosition}>
          <ItemsList
            menuId={uid}
            menuItem={menuItem}
            showAllItemOnInitialList={showAllItem ?? false}
            open={menuOpen}
            onSelectItem={(newSelectedItem, e) => {
              if (newSelectedItem === selectedItem) handleToggleMenu(false);
              onSelectItem?.(newSelectedItem, e);
            }}
            className="flex h-full w-48 flex-col bg-white dark:bg-dark-gray"
          />
        </div>
      ) : null}
    </div>
  );
};

const OverlayMenu = ({
  buttonLabel,
  footer,
  menuTop,
  ...extraAriaAttrs
}: {
  buttonLabel?: string | undefined;
  footer?: React.ReactNode;
  menuTop?: string | undefined;
} & React.AriaAttributes) => {
  const { onSelectItem, selectedItem, topLevelMenuItems } = useMenuContext();
  const [menuOpen, setMenuOpen] = React.useState(false);
  React.useEffect(() => setMenuOpen(false), [selectedItem]);
  const overlayMenuUID = React.useId();

  return (
    <>
      <Button
        color="filled"
        onClick={() => setMenuOpen(true)}
        aria-controls={overlayMenuUID}
        aria-expanded={menuOpen}
        aria-haspopup="menu"
        aria-label={buttonLabel ?? "Open Menu"}
        {...extraAriaAttrs}
      >
        <Icon name="filter" />
      </Button>
      <Sheet
        open={menuOpen}
        onOpenChange={setMenuOpen}
        modal
        className="right-auto w-80 max-w-80 border-l-0 p-0 md:left-0 md:border-r"
      >
        <ItemsList
          menuId={overlayMenuUID}
          menuItem={{
            key: "items#key",
            label: buttonLabel ?? "More",
            children: topLevelMenuItems,
            parent: null,
          }}
          footer={footer}
          open={menuOpen}
          onSelectItem={(newSelectedItem, e) => {
            setMenuOpen(false);
            onSelectItem?.(newSelectedItem, e);
          }}
          className="h-full overflow-x-hidden overflow-y-auto"
        />
      </Sheet>
    </>
  );
};

const ItemsList = ({
  menuId,
  menuItem: initialMenuItem,
  showAllItemOnInitialList,
  open,
  onSelectItem,
  footer,
  className,
}: {
  menuId?: string;
  menuItem: MenuItemWithChildren;
  showAllItemOnInitialList?: boolean;
  open: boolean;
  onSelectItem?: SelectItemHandler;
  footer?: React.ReactNode;
  className?: string;
}) => {
  const [displayedItem, setDisplayedItem] = React.useState(initialMenuItem);
  React.useEffect(() => setDisplayedItem(initialMenuItem), [open]);
  return (
    <div
      id={menuId}
      style={displayedItem.css}
      role="menu"
      aria-label={displayedItem.label}
      className={classNames("overflow-hidden border-none! p-0! shadow-none!", className)}
    >
      {footer}
      {displayedItem.key !== initialMenuItem.key ? (
        <MenuItemLink
          key={`back${displayedItem.key}`}
          href={displayedItem.parent?.href ?? "#"}
          onClick={(e) => {
            if (e.ctrlKey || e.shiftKey) return;
            setDisplayedItem(displayedItem.parent ?? initialMenuItem);
            e.preventDefault();
          }}
        >
          <Icon name="outline-cheveron-left" />
          <span>Back</span>
        </MenuItemLink>
      ) : null}
      {displayedItem.key !== initialMenuItem.key || showAllItemOnInitialList ? (
        <MenuItemLink href={displayedItem.href} onClick={(e) => onSelectItem?.(displayedItem, e)}>
          All {displayedItem.label}
        </MenuItemLink>
      ) : null}
      {displayedItem.children.map((item) => (
        <MenuItemLink
          key={item.key}
          href={item.href}
          onClick={(e) => {
            if (item.children.length) {
              if (e.ctrlKey || e.shiftKey) return;
              e.preventDefault();
              setDisplayedItem(item);
            } else return onSelectItem?.(item, e);
          }}
          className={item.children.length ? "flex! items-start! no-underline!" : undefined}
          aria-haspopup={item.children.length ? "menu" : undefined}
        >
          <span className="min-w-0 flex-1 overflow-visible! break-words">{item.label}</span>
          {item.children.length > 0 && <Icon name="outline-cheveron-right" className="shrink-0" />}
        </MenuItemLink>
      ))}
      {displayedItem.image ? <img src={displayedItem.image} className="w-full translate-x-6 translate-y-6" /> : null}
    </div>
  );
};

const MenuItemLink = ({
  className,
  children,
  ...props
}: {
  children: React.ReactNode;
} & React.ComponentProps<"a">) => (
  <a
    {...props}
    href={props.href ?? "#"}
    className={classNames(
      "shrink-0 justify-between gap-2 overflow-visible! p-4! whitespace-normal! hover:bg-primary! hover:text-background!",
      className,
    )}
    role="menuitem"
  >
    {children}
  </a>
);
