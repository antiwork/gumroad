import { usePage } from "@inertiajs/react";
import React from "react";

import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

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
      <Table>
        <TableCaption>Action Call Dashboard</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>#</TableHead>
            <TableHead>Controller</TableHead>
            <TableHead>Action</TableHead>
            <TableHead>Call Count</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {adminActionCallInfos.map((info, index) => (
            <TableRow key={info.id}>
              <TableCell label="#">{index + 1}</TableCell>
              <TableCell label="Controller">{info.controller_name}</TableCell>
              <TableCell label="Action">{info.action_name}</TableCell>
              <TableCell label="Call Count">{info.call_count}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </section>
  );
};

export default AdminActionCallDashboard;
