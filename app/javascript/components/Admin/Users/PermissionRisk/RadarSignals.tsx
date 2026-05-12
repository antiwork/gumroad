import React from "react";

import type { RecentEfw, User } from "$app/components/Admin/Users/User";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Pill } from "$app/components/ui/Pill";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type RadarSignalsProps = {
  user: User;
};

const disputeRateColor = (rate: number): string => {
  if (rate > 1) return "text-danger";
  if (rate >= 0.5) return "text-warning";
  return "text-success";
};

const efwCountColor = (count: number): string => {
  if (count >= 3) return "text-danger";
  if (count >= 1) return "text-warning";
  return "text-success";
};

const riskLevelPillColor = (level: string): "danger" | "warning" | undefined => {
  switch (level) {
    case "highest":
      return "danger";
    case "elevated":
      return "warning";
    default:
      return undefined;
  }
};

const formatDate = (iso: string) => {
  const d = new Date(iso);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
};

const RadarSignals = ({ user }: RadarSignalsProps) => {
  const stats = user.radar_stats;
  const recentEfws: RecentEfw[] = user.recent_efws ?? [];

  if (!stats) return null;

  const fraudTypeEntries: [string, number][] = Object.entries(stats.efw_by_fraud_type);

  return (
    <>
      <hr />
      <Details>
        <DetailsToggle>
          <h3>Radar signals (90 days)</h3>
        </DetailsToggle>
        <div className="grid gap-4">
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Successful purchases</span>
              <p className="text-lg font-medium">{stats.successful_purchases}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">EFW count</span>
              <p className={`text-lg font-medium ${efwCountColor(stats.efw_count)}`}>{stats.efw_count}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Dispute count</span>
              <p className="text-lg font-medium">{stats.dispute_count}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Dispute rate</span>
              <p className={`text-lg font-medium ${disputeRateColor(stats.dispute_rate)}`}>{stats.dispute_rate}%</p>
            </div>
          </div>

          {(stats.efw_with_elevated_risk > 0 || stats.efw_with_highest_risk > 0) && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">EFW risk levels</span>
              <div className="flex gap-3">
                {stats.efw_with_elevated_risk > 0 && (
                  <Pill color="warning" size="small">
                    Elevated: {stats.efw_with_elevated_risk}
                  </Pill>
                )}
                {stats.efw_with_highest_risk > 0 && (
                  <Pill color="danger" size="small">
                    Highest: {stats.efw_with_highest_risk}
                  </Pill>
                )}
              </div>
            </div>
          )}

          {fraudTypeEntries.length > 0 && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">EFW by fraud type</span>
              <div className="flex flex-wrap gap-2">
                {fraudTypeEntries.map(([type, count]) => (
                  <Pill key={type} size="small">
                    {type.replace(/_/gu, " ")}: {count}
                  </Pill>
                ))}
              </div>
            </div>
          )}

          {recentEfws.length > 0 && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">Recent EFWs</span>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Reference</TableHead>
                    <TableHead>Fraud type</TableHead>
                    <TableHead>Risk level</TableHead>
                    <TableHead>Resolution</TableHead>
                    <TableHead>Date</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {recentEfws.map((efw, idx) => (
                    <TableRow key={idx}>
                      <TableCell className="font-mono text-xs">{efw.purchase_id ?? "—"}</TableCell>
                      <TableCell>{efw.fraud_type.replace(/_/gu, " ")}</TableCell>
                      <TableCell>
                        <Pill color={riskLevelPillColor(efw.charge_risk_level)} size="small">
                          {efw.charge_risk_level}
                        </Pill>
                      </TableCell>
                      <TableCell>{efw.resolution.replace(/_/gu, " ")}</TableCell>
                      <TableCell className="text-muted">{formatDate(efw.created_at)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </div>
      </Details>
    </>
  );
};

export default RadarSignals;
