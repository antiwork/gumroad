// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { type AnalyticsFileDownloads } from "$app/data/analytics";

import { FileDownloadsTable } from "$app/components/Analytics/FileDownloadsTable";

afterEach(cleanup);

const file = (overrides: Partial<AnalyticsFileDownloads>): AnalyticsFileDownloads => ({
  id: "file",
  product_permalink: "guide",
  product_name: "Guide",
  name: "Chapter 1",
  deleted: false,
  downloads: 1,
  unique_buyers: 1,
  ...overrides,
});

const files = [
  file({ id: "a", name: "Chapter 1", downloads: 3, unique_buyers: 2 }),
  file({ id: "b", name: "Old chapter", deleted: true, downloads: 7, unique_buyers: 5 }),
  file({ id: "c", product_permalink: "course", product_name: "Course", name: "Lesson 1", downloads: 9 }),
];

// Each cell repeats its column label for the mobile layout, so a value reads as "Downloads3".
const rows = () =>
  [...document.querySelectorAll("tbody tr")].map((row) =>
    [...row.querySelectorAll("td")].map((cell) => cell.textContent?.trim() ?? ""),
  );

describe("FileDownloadsTable", () => {
  it("lists only the selected products' files, most downloaded first", () => {
    render(<FileDownloadsTable files={files} selectedProducts={["guide"]} />);

    expect(rows().map((row) => row[0])).toEqual(["FileOld chapter (deleted)", "FileChapter 1"]);
    expect(rows()[1]).toEqual(["FileChapter 1", "ProductGuide", "Downloads3", "Unique buyers2"]);
  });

  it("says when the selected products have no downloads in the range", () => {
    render(<FileDownloadsTable files={files} selectedProducts={["other"]} />);

    expect(screen.getByText("Nothing yet")).toBeTruthy();
  });

  it("says when the counts could not be loaded", () => {
    render(<FileDownloadsTable files={null} selectedProducts={["guide"]} />);

    expect(screen.getByText("We couldn't load downloads for this range.")).toBeTruthy();
  });
});
