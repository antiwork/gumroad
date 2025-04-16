import React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Layout } from "$app/components/server-components/EmailsPage";

export const SegmentsTab = () => {
  const [selectedSegmentId, setSelectedSegmentId] = React.useState<string | null>(null);
  const [openPopoverId, setOpenPopoverId] = React.useState<string | null>(null);

  const segments = [
    {
      external_id: "1",
      name: "Active subscribers",
      created_at: new Date("2025-02-13T00:00:00Z"),
      last_used_at: new Date("2025-02-14T00:00:00Z"),
      subscriber_count: 1302,
      opens_rate: 0,
      clicks_rate: 0,
    },
    {
      external_id: "2",
      name: "Casual subscribers",
      created_at: new Date("2025-05-01T00:00:00Z"),
      last_used_at: new Date("2025-05-01T00:00:00Z"),
      subscriber_count: 830,
      opens_rate: 0,
      clicks_rate: 0,
    },
    {
      external_id: "3",
      name: "Cold subscribers",
      created_at: new Date("2025-04-27T00:00:00Z"),
      last_used_at: new Date("2025-04-27T00:00:00Z"),
      subscriber_count: 567,
      opens_rate: 0,
      clicks_rate: 0,
    },
  ];

  return (
    <Layout selectedTab="segments">
      <div>
        <table aria-label="Segments" style={{ marginBottom: "var(--spacer-4)", width: "100%" }} aria-live="polite">
          <thead>
            <tr>
              <th>Name</th>
              <th>Created</th>
              <th>Last used</th>
              <th>Audience</th>
              <th>Opens</th>
              <th>Clicks</th>
              <th aria-label="Actions"></th>
            </tr>
          </thead>
          <tbody>
            {segments.map((segment) => (
              <tr
                key={segment.external_id}
                aria-selected={segment.external_id === selectedSegmentId}
                onClick={() => setSelectedSegmentId(segment.external_id)}
                style={{ cursor: "pointer" }}
              >
                <td data-label="Name">{segment.name}</td>
                <td data-label="Created" style={{ whiteSpace: "nowrap" }}>
                  {segment.created_at.toLocaleDateString()}
                </td>
                <td data-label="Last used" style={{ whiteSpace: "nowrap" }}>
                  {segment.last_used_at.toLocaleDateString()}
                </td>
                <td data-label="Audience" style={{ whiteSpace: "nowrap" }}>
                  {segment.subscriber_count.toLocaleString()}
                </td>
                <td data-label="Opens">{segment.opens_rate}%</td>
                <td data-label="Clicks">{segment.clicks_rate}%</td>
                <td>
                  <div style={{ display: "flex", gap: "var(--spacer-2)" }}>
                    <Button className="icon-button" aria-label="Edit segment">
                      <Icon name="pencil" />
                    </Button>
                    <Popover
                      open={openPopoverId === segment.external_id}
                      onToggle={(open) => setOpenPopoverId(open ? segment.external_id : null)}
                      trigger={
                        <Button
                          className="icon-button"
                          aria-label="More actions"
                          onClick={(e) => {
                            e.stopPropagation();
                            setOpenPopoverId(openPopoverId === segment.external_id ? null : segment.external_id);
                          }}
                        >
                          <Icon name="three-dots" />
                        </Button>
                      }
                      position="bottom"
                    >
                      {(close) => (
                        <div style={{ minWidth: 120, display: "flex", flexDirection: "column" }}>
                          <button
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: 8,
                              padding: "8px 16px",
                              background: "none",
                              border: "none",
                              width: "100%",
                              cursor: "pointer",
                              font: "inherit",
                            }}
                            onClick={() => {
                              close();
                            }}
                          >
                            <Icon name="outline-duplicate" />
                            Duplicate
                          </button>
                          <button
                            style={{
                              display: "flex",
                              alignItems: "center",
                              gap: 8,
                              padding: "8px 16px",
                              background: "none",
                              border: "none",
                              width: "100%",
                              color: "var(--danger)",
                              cursor: "pointer",
                              font: "inherit",
                            }}
                            onClick={() => {
                              close();
                            }}
                          >
                            <Icon name="trash2" />
                            Delete
                          </button>
                        </div>
                      )}
                    </Popover>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Layout>
  );
};
