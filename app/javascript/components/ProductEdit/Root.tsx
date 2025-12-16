import * as React from "react";
import { Outlet, useLocation } from "react-router-dom";
import { useProductEditContext } from "./state";

// TODO(Tri): Organize; Check if isDirty

export const ProductEditRoot = () => {
  const { save, saving, isBlocked } = useProductEditContext();
  const location = useLocation();
  const lastPathRef = React.useRef(location.pathname);

  React.useEffect(() => {
    if (lastPathRef.current !== location.pathname) {
      lastPathRef.current = location.pathname;

      if (!saving && !isBlocked) {
        void save();
      }

    //   if (__DEV__) {
        console.debug("[autosave] route-change", {
            from: lastPathRef.current,
            to: location.pathname,
            saving,
            isBlocked,
        });
        }
    // }
  }, [location.pathname, save, saving, isBlocked]);

  return <Outlet />;
};
