import cx from "classnames";
import * as React from "react";
import ReactSelect, {
  components,
  InputProps,
  MenuListProps,
  MultiValueProps,
  OptionProps,
  Props as ReactSelectProps,
  DropdownIndicatorProps,
  ControlProps,
  ClearIndicatorProps,
  GroupBase,
  SelectInstance,
} from "react-select";

import { escapeRegExp } from "$app/utils";

import { Icon } from "$app/components/Icons";

export type Option = { id: string; label: string; isSubOption?: boolean; disabled?: boolean };

export type CustomOption = (option: Option) => React.ReactNode;
type CustomProps = {
  customOption: null | CustomOption;
  menuListId: null | string;
  focusedOptionId: null | string;
  setFocusedOptionId?: (id: null | string) => void;
  maxLength: number | null;
};
const CustomPropsContext = React.createContext<CustomProps>({
  customOption: null,
  menuListId: null,
  focusedOptionId: null,
  maxLength: null,
});

export type Props<IsMulti extends boolean = boolean> = Omit<
  ReactSelectProps<Option, IsMulti>,
  | "components"
  | "getOptionLabel"
  | "getOptionValue"
  | "openMenuOnFocus"
  | "menuIsOpen"
  | "onMenuOpen"
  | "onMenuClose"
  | "filterOption"
  | "styles"
> & {
  customOption?: CustomOption;
  allowMenuOpen?: () => boolean;
  maxLength?: number;
};

// Forward a ref to react-select so parents can call .focus(), .blur(), etc.
const SelectInner = <IsMulti extends boolean>(
  props: Props<IsMulti>,
  ref: React.ForwardedRef<SelectInstance<Option, IsMulti, GroupBase<Option>>>,
) => {
  const [isMenuOpen, setIsMenuOpen] = React.useState(false);
  const [focusedOptionId, setFocusedOptionId] = React.useState<null | string>(null);

  const handleMenuOpen = () => {
    setIsMenuOpen(true);
  };

  const handleMenuClose = () => {
    setIsMenuOpen(false);
    setFocusedOptionId(null);
  };

  const menuListId = React.useId();
  const customProps = React.useMemo(
    () => ({
      customOption: props.customOption ?? null,
      menuListId,
      focusedOptionId,
      setFocusedOptionId,
      maxLength: props.maxLength ?? null,
    }),
    [props.customOption, focusedOptionId],
  );

  return (
    <CustomPropsContext.Provider value={customProps}>
      <ReactSelect
        {...props}
        ref={ref}
        isOptionDisabled={(option) => option.disabled ?? false}
        instanceId={props.inputId ?? menuListId}
        className={cx("combobox", props.className)}
        components={{
          ClearIndicator,
          Control,
          DropdownIndicator,
          IndicatorSeparator,
          Input,
          LoadingIndicator,
          MenuList,
          MultiValue,
          Option,
        }}
        getOptionLabel={(option) => option.label}
        getOptionValue={(option) => option.id}
        openMenuOnFocus
        menuIsOpen={isMenuOpen}
        onMenuClose={handleMenuClose}
        onMenuOpen={() => ((props.allowMenuOpen?.() ?? true) ? handleMenuOpen() : null)}
        filterOption={filterOptionFn}
        formatOptionLabel={formatOptionLabel}
        styles={{
          clearIndicator: () => ({}),
          control: () => ({}),
          dropdownIndicator: () => ({}),
          indicatorsContainer: () => ({ display: "contents" }),
          input: (baseCSS) => ({ ...baseCSS, margin: 0, padding: 0, color: undefined }),
          menu: () => ({}),
          placeholder: (baseCSS) => ({ ...baseCSS, margin: 0 }),
          singleValue: (baseCSS) => ({ ...baseCSS, margin: 0, color: undefined }),
          valueContainer: (baseCSS, props) => ({
            ...baseCSS,
            padding: 0,
            ...(props.selectProps.menuIsOpen ? { borderBottomLeftRadius: 0, borderBottomRightRadius: 0 } : {}),
            ...(Array.isArray(props.selectProps.value) && props.selectProps.value.length > 0
              ? { margin: "var(--spacer-1) calc(var(--spacer-2) * -1)", gap: "var(--spacer-1) var(--spacer-2)" }
              : { margin: 0 }),
          }),
        }}
      />
    </CustomPropsContext.Provider>
  );
};

/* eslint-disable-next-line @typescript-eslint/consistent-type-assertions */
export const Select = React.forwardRef(SelectInner) as unknown as <IsMulti extends boolean>(
  props: Props<IsMulti> & {
    ref?: React.Ref<SelectInstance<Option, IsMulti, GroupBase<Option>>>;
  },
) => React.ReactElement;

// Regex groupings are important to be kept in sync with `formatOptionLabel` method
const filterRegex = (query: string) => new RegExp(`(.*?)(${escapeRegExp(query)})(.*)`, "iu");

const filterOptionFn: ReactSelectProps<Option>["filterOption"] = ({ data: { disabled }, label }, query) => {
  if (query.length === 0) return true;
  if (disabled) return false;
  return filterRegex(query).test(label);
};

const formatOptionLabel: NonNullable<ReactSelectProps<Option>["formatOptionLabel"]> = (
  { label, isSubOption },
  { inputValue },
) => {
  const result = inputValue.length > 0 ? filterRegex(inputValue).exec(label) : null;

  if (result) {
    const [_, before, matchingInput, after] = result;
    return (
      <span>
        {before}
        <em>{matchingInput}</em>
        {after}
      </span>
    );
  }
  return (
    <span>
      {isSubOption ? <Icon name="arrow-right-reply" className="mr-2" /> : null}
      {label}
    </span>
  );
};

const LoadingIndicator = () => null;
const IndicatorSeparator = () => null;

const ClearIndicator = <IsMulti extends boolean>(props: ClearIndicatorProps<Option, IsMulti>) => (
  <components.ClearIndicator {...props}>
    <button aria-label="Clear value">
      <Icon name="x" />
    </button>
  </components.ClearIndicator>
);

const DropdownIndicator = <IsMulti extends boolean>(props: DropdownIndicatorProps<Option, IsMulti>) =>
  props.isMulti ? null : (
    <components.DropdownIndicator {...props}>
      <Icon name="outline-cheveron-down" />
    </components.DropdownIndicator>
  );

const Control = <IsMulti extends boolean>(props: ControlProps<Option, IsMulti>) => (
  <components.Control className={cx("input", props.isDisabled ? "disabled" : null)} {...props}>
    {props.children}
  </components.Control>
);

const MenuList = <IsMulti extends boolean>(props: MenuListProps<Option, IsMulti>) => {
  const menuListId = React.useContext(CustomPropsContext).menuListId;

  return (
    <datalist
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- react-select incorrectly types this as div
      ref={props.innerRef as React.Ref<HTMLDataListElement>}
      style={{ maxHeight: props.maxHeight }}
      id={menuListId ?? undefined}
    >
      {props.children}
    </datalist>
  );
};

const MultiValue = <IsMulti extends boolean>(props: MultiValueProps<Option, IsMulti>) => (
  <div {...props.removeProps}>
    <button className="pill primary dismissable">{props.data.label}</button>
  </div>
);

const Input = <IsMulti extends boolean>(props: InputProps<Option, IsMulti>) => {
  const customProps = React.useContext(CustomPropsContext);

  // override the inner aria-owns and aria-controls as they point to the incorrect id
  return (
    <components.Input
      {...props}
      aria-owns={customProps.menuListId ?? undefined}
      aria-controls={customProps.menuListId ?? undefined}
      aria-haspopup="listbox"
      aria-activedescendant={customProps.focusedOptionId ?? undefined}
      maxLength={customProps.maxLength ?? undefined}
    />
  );
};

const Option = <IsMulti extends boolean>(props: OptionProps<Option, IsMulti>) => {
  const innerProps = props.innerProps;
  const customProps = React.useContext(CustomPropsContext);

  React.useEffect(() => {
    if (props.isFocused) customProps.setFocusedOptionId?.(innerProps.id ?? null);
  }, [props.isFocused]);

  return (
    <div
      className={cx({ focused: props.isFocused })}
      ref={props.innerRef}
      id={innerProps.id}
      key={innerProps.key}
      onClick={innerProps.onClick}
      onMouseMove={innerProps.onMouseMove}
      onMouseOver={innerProps.onMouseOver}
      tabIndex={innerProps.tabIndex}
      role="option"
    >
      {customProps.customOption?.({ id: props.label, label: props.label }) ?? props.children}
    </div>
  );
};
