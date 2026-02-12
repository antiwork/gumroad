import { CheckCircle, XCircle } from "@boxicons/react";
import * as React from "react";

export const YesIcon = () => <CheckCircle pack="filled" aria-label="Yes" className="text-success" />;
export const NoIcon = () => <XCircle pack="filled" aria-label="No" className="text-danger" />;

export const BooleanIcon = ({ value }: { value: boolean }) => (value ? <YesIcon /> : <NoIcon />);
