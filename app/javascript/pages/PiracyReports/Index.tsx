import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import {
  formatPiracyReportDate,
  piracyReportStatus,
  PiracyReportOutcome,
  PiracyReportState,
} from "$app/data/piracy_reports";

import { ProductsLayout } from "$app/components/ProductsLayout";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type PiracyReportsIndexProps = {
  archived_tab_visible: boolean;
  can_report: boolean;
  reports: {
    id: string;
    product_name: string;
    url: string;
    state: PiracyReportState;
    outcome: PiracyReportOutcome | null;
    updated_at: string;
  }[];
};

export default function PiracyReportsIndex() {
  const { archived_tab_visible, can_report, reports } = usePage<PiracyReportsIndexProps>().props;

  return (
    <ProductsLayout
      selectedTab="piracy_reports"
      title="Products"
      archivedTabVisible={archived_tab_visible}
      piracyReportsTabVisible
    >
      <div className="p-4 md:p-8">
        {reports.length === 0 ? (
          <Placeholder>
            <p>You have not reported any pages yet.</p>
            {can_report ? (
              <p>To report one, open a product's menu on the Products page and choose Report piracy.</p>
            ) : null}
          </Placeholder>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Product</TableHead>
                <TableHead>Page</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Updated</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {reports.map((report) => {
                const status = piracyReportStatus(report.state, report.outcome);
                return (
                  <TableRow key={report.id}>
                    <TableCell>
                      <Link href={Routes.piracy_report_path(report.id)}>{report.product_name}</Link>
                    </TableCell>
                    <TableCell className="break-all">{report.url}</TableCell>
                    <TableCell>
                      <Pill size="small" color={status.color}>
                        {status.label}
                      </Pill>
                    </TableCell>
                    <TableCell>{formatPiracyReportDate(report.updated_at)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </div>
    </ProductsLayout>
  );
}
