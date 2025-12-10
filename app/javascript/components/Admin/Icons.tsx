import * as React from "react";

import { Icon } from "$app/components/Icons";

export const YesIcon = () => <Icon name="solid-check-circle" aria-label="Yes" className="text-success" />;
export const NoIcon = () => <Icon name="x-circle-fill" aria-label="No" className="text-danger" />;

export const BooleanIcon = ({ value }: { value: boolean }) => (value ? <YesIcon /> : <NoIcon />);
