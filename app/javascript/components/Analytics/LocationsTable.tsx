import * as React from "react";

import { AnalyticsDataByState, LocationDataValue } from "$app/data/analytics";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

type TableEntry = {
  name: string;
  totals: number;
  sales: number;
  views: number;
};

type TableData = {
  locationData: AnalyticsDataByState;
  selectedProducts: string[];
  locations: Record<string, string>;
  caption: React.ReactNode;
};

const CountryFlag = ({ countryCode }: { countryCode: string }) => {
  const unicodeRegionChars = countryCode.split("").map((char) => 127397 + char.charCodeAt(0));
  const flag = String.fromCodePoint(...unicodeRegionChars);

  return <span>{flag || " "} </span>;
};

const prepareValue = (input: LocationDataValue | undefined) =>
  Array.isArray(input) ? input.reduce((acc, curr) => acc + curr, 0) : (input ?? 0);

const updateTableRow = (
  tableData: Map<string, TableEntry>,
  title: string,
  totals: number,
  sales: number,
  views: number,
) => {
  if (!totals && !sales && !views) return;

  const prev = tableData.get(title) || { name: "", totals: 0, sales: 0, views: 0 };
  const curr = {
    name: title || "Other",
    totals: prev.totals + totals,
    sales: prev.sales + sales,
    views: prev.views + views,
  };

  tableData.set(title, curr);
};

export const AnalyticsCountriesTable = ({
  locationData,
  selectedProducts,
  locations: countries,
  caption,
}: TableData) => {
  const countriesData = React.useMemo(() => {
    const { totals, sales, views } = locationData.by_state;
    const tableData = new Map<string, TableEntry>();

    for (const [productId, productTotals] of Object.entries(totals)) {
      if (!selectedProducts.includes(productId)) continue;

      for (const [country, total] of Object.entries(productTotals)) {
        const totalsVal = prepareValue(total);
        const salesVal = prepareValue(sales[productId]?.[country]);
        const viewsVal = prepareValue(views[productId]?.[country]);

        updateTableRow(tableData, country, totalsVal, salesVal, viewsVal);
      }
    }

    return [...tableData.values()];
  }, [locationData, selectedProducts]);
  const { items, thProps } = useClientSortingTableDriver(countriesData, {
    key: "totals",
    direction: "desc",
  });

  return (
    <Table>
      <TableCaption>{caption}</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead {...thProps("name")}>Country</TableHead>
          <TableHead {...thProps("views")}>Views</TableHead>
          <TableHead {...thProps("sales")}>Sales</TableHead>
          <TableHead {...thProps("totals")}>Total</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.length ? (
          items.map(({ name, totals, sales, views }) => (
            <TableRow key={name}>
              <TableCell>
                <CountryFlag countryCode={countries[name] || ""} />
                {name}
              </TableCell>
              <TableCell>{views}</TableCell>
              <TableCell>{sales}</TableCell>
              <TableCell>
                {formatPriceCentsWithCurrencySymbol("usd", totals, { symbolFormat: "short", noCentsIfWhole: true })}
              </TableCell>
            </TableRow>
          ))
        ) : (
          <TableRow>
            <TableCell colSpan={4}>Nothing yet</TableCell>
          </TableRow>
        )}
      </TableBody>
    </Table>
  );
};

export const AnalyticsStatesTable = ({ locationData, selectedProducts, locations: states, caption }: TableData) => {
  const statesData = React.useMemo(() => {
    const { totals, sales, views } = locationData.by_state;
    const tableStatesData = new Map<string, TableEntry>();

    for (const [productId, productTotals] of Object.entries(totals)) {
      if (!selectedProducts.includes(productId)) continue;

      for (const [country, totalsValue] of Object.entries(productTotals)) {
        const salesValue = sales[productId]?.[country],
          viewsValue = views[productId]?.[country];

        if (Array.isArray(totalsValue) && Array.isArray(salesValue) && Array.isArray(viewsValue)) {
          totalsValue.forEach((_val, state) => {
            const title = states[state];
            if (!title) return;
            updateTableRow(
              tableStatesData,
              title,
              totalsValue[state] ?? 0,
              salesValue[state] ?? 0,
              viewsValue[state] ?? 0,
            );
          });
        }
      }
    }
    return [...tableStatesData.values()];
  }, [locationData, selectedProducts]);
  const { items, thProps } = useClientSortingTableDriver(statesData, {
    key: "totals",
    direction: "desc",
  });

  return (
    <>
      <Table>
        <TableCaption>{caption}</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead {...thProps("name")}>State</TableHead>
            <TableHead {...thProps("views")}>Views</TableHead>
            <TableHead {...thProps("sales")}>Sales</TableHead>
            <TableHead {...thProps("totals")}>Total</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map(({ name, totals, sales, views }) => (
            <TableRow key={name}>
              <TableCell>{name}</TableCell>
              <TableCell>{views}</TableCell>
              <TableCell>{sales}</TableCell>
              <TableCell>
                {formatPriceCentsWithCurrencySymbol("usd", totals, { symbolFormat: "short", noCentsIfWhole: true })}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      {!items.length ? <div className="input mt-4 lg:mt-0">Nothing yet </div> : null}
    </>
  );
};

export const LocationsTable = ({
  data,
  selectedProducts,
  countryCodes,
  stateNames,
}: {
  data: AnalyticsDataByState;
  selectedProducts: string[];
  countryCodes: Record<string, string>;
  stateNames: Record<string, string>;
}) => {
  const [selected, setSelected] = React.useState("world");

  const caption = (
    <div className="flex justify-between">
      Locations
      <select aria-label="Locations" className="w-fit" value={selected} onChange={(ev) => setSelected(ev.target.value)}>
        <option value="world">World</option>
        <option value="us">United States</option>
      </select>
    </div>
  );

  return (
    <section>
      {selected === "world" ? (
        <AnalyticsCountriesTable
          locationData={data}
          selectedProducts={selectedProducts}
          locations={countryCodes}
          caption={caption}
        />
      ) : (
        <AnalyticsStatesTable
          locationData={data}
          selectedProducts={selectedProducts}
          locations={stateNames}
          caption={caption}
        />
      )}
    </section>
  );
};
