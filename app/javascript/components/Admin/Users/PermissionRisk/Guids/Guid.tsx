import { Link } from "@inertiajs/react";
import React from "react";

type GuidProps = {
  guid: string;
  user_ids: number[];
};

const Guid = ({ guid, user_ids }: GuidProps) => (
  <div>
    <h5>
      <Link href={Routes.admin_compliance_guids_path(guid)}>{guid}</Link>
    </h5>
    <span>{user_ids.length} users</span>
  </div>
);

export default Guid;
