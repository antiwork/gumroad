import * as React from "react";
import { Outlet, useLocation } from "react-router-dom";
import { useProductEditContext } from "./state";

export const ProductEditRoot = () => {
  const { save, saving, isBlocked, isDirty } = useProductEditContext();
  const location = useLocation();
  const lastPathRef = React.useRef(location.pathname);

  React.useEffect(() => {
    if (lastPathRef.current !== location.pathname) {
      lastPathRef.current = location.pathname;

      if (!saving && !isBlocked && isDirty) {
        void save();
      }
    }
  }, [location.pathname, save, saving, isBlocked, isDirty]);

  return <Outlet />;
};
