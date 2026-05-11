import React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { Details, DetailsToggle } from "$app/components/ui/Details";

type RadarSignalsProps = {
  user: User;
};

const disputeRateColor = (rate: number): string => {
  if (rate > 1) return "text-red-600";
  if (rate >= 0.5) return "text-yellow-600";
  return "text-green-600";
};

const efwCountColor = (count: number): string => {
  if (count >= 3) return "text-red-600";
  if (count >= 1) return "text-yellow-600";
  return "text-green-600";
};

const riskLevelBadge = (level: string): string => {
  switch (level) {
    case "highest":
      return "bg-red-100 text-red-800";
    case "elevated":
      return "bg-yellow-100 text-yellow-800";
    default:
      return "bg-gray-100 text-gray-800";
  }
};

const formatDate = (iso: string) => {
  const d = new Date(iso);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
};

const RadarSignals = ({ user }: RadarSignalsProps) => {
  const stats = user.radar_stats;
  const recentEfws = user.recent_efws ?? [];

  if (!stats) return null;

  const fraudTypeEntries = Object.entries(stats.efw_by_fraud_type);

  return (
    <>
      <hr />
      <Details>
        <DetailsToggle>
          <h3>Radar Signals (90 days)</h3>
        </DetailsToggle>
        <div className="grid gap-4">
          {/* Summary stats */}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Total Purchases</span>
              <p className="text-lg font-medium">{stats.total_purchases}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">EFW Count</span>
              <p className={`text-lg font-medium ${efwCountColor(stats.efw_count)}`}>{stats.efw_count}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Dispute Count</span>
              <p className="text-lg font-medium">{stats.dispute_count}</p>
            </div>
            <div className="rounded border border-border p-3">
              <span className="text-xs tracking-wide text-muted uppercase">Dispute Rate</span>
              <p className={`text-lg font-medium ${disputeRateColor(stats.dispute_rate)}`}>{stats.dispute_rate}%</p>
            </div>
          </div>

          {/* Risk level breakdown */}
          {(stats.efw_with_elevated_risk > 0 || stats.efw_with_highest_risk > 0) && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">EFW Risk Levels</span>
              <div className="flex gap-3">
                {stats.efw_with_elevated_risk > 0 && (
                  <span className="inline-flex items-center rounded-full bg-yellow-100 px-2.5 py-0.5 text-xs font-medium text-yellow-800">
                    Elevated: {stats.efw_with_elevated_risk}
                  </span>
                )}
                {stats.efw_with_highest_risk > 0 && (
                  <span className="inline-flex items-center rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-800">
                    Highest: {stats.efw_with_highest_risk}
                  </span>
                )}
              </div>
            </div>
          )}

          {/* Fraud type breakdown */}
          {fraudTypeEntries.length > 0 && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">EFW by Fraud Type</span>
              <div className="flex flex-wrap gap-2">
                {fraudTypeEntries.map(([type, count]) => (
                  <span
                    key={type}
                    className="inline-flex items-center rounded-full bg-gray-100 px-2.5 py-0.5 text-xs font-medium text-gray-800"
                  >
                    {type.replace(/_/gu, " ")}: {count}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Recent EFWs table */}
          {recentEfws.length > 0 && (
            <div className="grid gap-1">
              <span className="text-xs font-medium tracking-wide text-muted uppercase">Recent EFWs</span>
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr className="border-b border-border text-xs text-muted uppercase">
                      <th className="px-2 py-1">Purchase ID</th>
                      <th className="px-2 py-1">Fraud Type</th>
                      <th className="px-2 py-1">Risk Level</th>
                      <th className="px-2 py-1">Resolution</th>
                      <th className="px-2 py-1">Date</th>
                    </tr>
                  </thead>
                  <tbody>
                    {recentEfws.map((efw, idx) => (
                      <tr key={idx} className="border-b border-border last:border-0">
                        <td className="px-2 py-1 font-mono text-xs">{efw.purchase_id ?? "—"}</td>
                        <td className="px-2 py-1">{efw.fraud_type.replace(/_/gu, " ")}</td>
                        <td className="px-2 py-1">
                          <span
                            className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${riskLevelBadge(efw.charge_risk_level)}`}
                          >
                            {efw.charge_risk_level}
                          </span>
                        </td>
                        <td className="px-2 py-1">{efw.resolution.replace(/_/gu, " ")}</td>
                        <td className="px-2 py-1 text-muted">{formatDate(efw.created_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      </Details>
    </>
  );
};

export default RadarSignals;
