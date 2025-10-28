import { usePage } from "@inertiajs/react";
import React from "react";

type ActionCallInfo = {
  id: number;
  controller_name: string;
  action_name: string;
  call_count: number;
};

type PageProps = {
  admin_action_call_infos: ActionCallInfo[];
};

const AdminActionCallDashboard = () => {
  const { admin_action_call_infos: adminActionCallInfos } = usePage<PageProps>().props;

  return (
    <section>
      <table className="w-full">
        <thead>
          <tr>
            <th className="text-left">#</th>
            <th className="text-left">Controller</th>
            <th className="text-left">Action</th>
            <th className="text-left">Call Count</th>
          </tr>
        </thead>
        <tbody>
          {adminActionCallInfos.map((info, index) => (
            <tr key={info.id}>
              <td>{index + 1}</td>
              <td>{info.controller_name}</td>
              <td>{info.action_name}</td>
              <td>{info.call_count}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
};

export default AdminActionCallDashboard;
