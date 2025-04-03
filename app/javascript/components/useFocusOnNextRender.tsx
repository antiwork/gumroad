import * as React from "react";

// Use this to help set focus on, for example, a new array element.
//
// Example:
//
// in parent component:
//
// 1. Initialize the hook
// 2. Call the returned `focusOnNextRender` function immediately after state change that added a new element
// 3. `shouldFocus` returned from the hook will turn `true` on the next render. use it to set focus on new element mount
//    (e.g. by passing in as a prop)
//
// const { shouldFocus, focusOnNextRender } = useFocusOnNextRender();
// <Button onClick={() => { createNewElement(); focusOnNextRender(); }}>+</Button>
// {elements.map(el => <Element shouldFocusOnMount={shouldFocus} />)}
//
// in child component:
//
// 1. Use the passed `shouldFocus` flag to set focus on mount
//
// const titleInputRef = React.useRef<HTMLInputElement | null>(null);
// React.useEffect(() => {
//   if (shouldFocusOnMount && titleInputRef.current != null) {
//     titleInputRef.current.focus();
//   }
// }, []);

export const useFocusOnNextRender = () => {
  const shouldFocusRef = React.useRef(false);
  React.useEffect(() => {
    if (shouldFocusRef.current) {
      shouldFocusRef.current = false;
    }
  });

  return {
    shouldFocus: shouldFocusRef.current,
    focusOnNextRender: () => {
      shouldFocusRef.current = true;
    },
  };
};
