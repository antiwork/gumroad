import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import {
  formatPiracyReportDate,
  piracyReportStatus,
  PiracyReportOutcome,
  PiracyReportState,
  withoutProtocol,
} from "$app/data/piracy_reports";

import { ProductsLayout } from "$app/components/ProductsLayout";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder } from "$app/components/ui/Placeholder";
import { StretchedLink } from "$app/components/ui/StretchedLink";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useUserAgentInfo } from "$app/components/UserAgent";

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
  const userAgentInfo = useUserAgentInfo();

  return (
    <ProductsLayout selectedTab="piracy_reports" archivedTabVisible={archived_tab_visible} piracyReportsTabVisible>
      <div className="p-4 md:p-8">
        {reports.length === 0 ? (
          <Placeholder>
            <h2>No piracy reports yet</h2>
            {can_report ? (
              <p>To report one, open a product's menu on the Products page and choose Report piracy.</p>
            ) : null}
          </Placeholder>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Reported page</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Updated</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {reports.map((report) => {
                const status = piracyReportStatus(report.state, report.outcome);
                return (
                  <TableRow key={report.id}>
                    <TableCell hideLabel className="relative">
                      <StretchedLink asChild>
                        <Link href={Routes.piracy_report_path(report.id)}>
                          <h4 className="font-bold break-all">{withoutProtocol(report.url)}</h4>
                        </Link>
                      </StretchedLink>
                      <small className="block" dir="auto">
                        {report.product_name}
                      </small>
                    </TableCell>
                    <TableCell>
                      <Pill size="small" color={status.color}>
                        {status.label}
                      </Pill>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {formatPiracyReportDate(report.updated_at, userAgentInfo.locale, "short")}
                    </TableCell>
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
