import { AbortError } from "$app/utils/request";

export interface Segment {
  external_id: string;
  name: string;
  created_at: Date;
  last_used_at: Date;
  subscriber_count: number;
  opens_rate: number;
  clicks_rate: number;
}

export interface Pagination {
  count: number;
  next: number | null;
}

export const getSegments = ({ query }: { page: number; query: string }) => {
  const controller = new AbortController();
  const signal = controller.signal;

  // Mock sample data
  const mockSegments: Segment[] = [
    {
      external_id: "1",
      name: "Active subscribers",
      created_at: new Date("2025-02-13T00:00:00Z"),
      last_used_at: new Date("2025-02-14T00:00:00Z"),
      subscriber_count: 1308,
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

  const promise = new Promise<{ segments: Segment[]; pagination: Pagination }>((resolve, reject) => {
    // Filter by query if provided
    const filteredSegments = query
      ? mockSegments.filter((segment) => segment.name.toLowerCase().includes(query.toLowerCase()))
      : mockSegments;

    // Simulate API delay
    setTimeout(() => {
      if (signal.aborted) {
        reject(new AbortError());
        return;
      }

      resolve({
        segments: filteredSegments,
        pagination: {
          count: filteredSegments.length,
          next: null, // No more pages in our mock
        },
      });
    }, 300);
  });

  return {
    response: promise,
    cancel: () => controller.abort(),
  };
};

export const deleteSegment = async (): Promise<void> =>
  // Simulate API delay
  new Promise((resolve) => {
    setTimeout(() => {
      resolve();
    }, 500);
  });
