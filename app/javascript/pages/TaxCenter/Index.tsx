import { Link, router, usePage } from "@inertiajs/react";
import taxesPlaceholder from "images/placeholders/taxes.png";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";

import { NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import Placeholder from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tab, Tabs } from "$app/components/ui/Tabs";

type TaxDocument = {
  document: string;
  type: string;
  year: number;
  form_type: string;
  gross: string;
  fees: string;
  taxes: string;
  affiliate_credit?: string;
  net: string;
};

const FAQ_ITEMS: {
  id: string;
  question: string;
  answer: React.ReactNode;
}[] = [
  {
    id: "why-1099-k",
    question: "Why did I receive a 1099-K?",
    answer: (
      <>
        You received a 1099-K if your U.S.-based Gumroad account had over $20,000 in gross sales and more than 200
        transactions in the previous calendar year. The 1099-K is a purely informational form that summarizes the sales
        activity of your account and is designed to assist you in reporting your taxes.{" "}
        <a href="/help/article/15-1099s" target="_blank" rel="noreferrer">
          Learn more
        </a>
        .
      </>
    ),
  },
  {
    id: "how-gross-sales-calculated",
    question: "How is the 'Gross Sales' amount on my 1099-K calculated?",
    answer: (
      <>
        The 1099-K shows your total unadjusted transaction volume, not your actual payouts. It includes Gumroad fees,
        VAT, affiliate commissions, and other adjustments, so it won't match the amount you were paid.{" "}
        <a href="/help/article/15-1099s#mismatch" target="_blank" rel="noreferrer">
          Learn more
        </a>
        .
      </>
    ),
  },
  {
    id: "find-gumroad-fees",
    question: "Where can I find my Gumroad fees to deduct on my tax return?",
    answer: (
      <>
        You can download a CSV file of your sales data within a selected date range from the{" "}
        <a href="/customers">Sales tab</a>. The CSV will include a <b>Fees</b> column which shows Gumroad's fees plus
        any Apple/Google in-app fees. If you use Stripe Connect or PayPal Connect, check the <b>Stripe Fee Amount</b>{" "}
        and <b>PayPal Fee Amount</b> columns for their respective processing fees.{" "}
        <a href="/help/article/74-the-analytics-dashboard#sales-csv" target="_blank" rel="noreferrer">
          Learn more
        </a>
        .
      </>
    ),
  },
  {
    id: "report-income-no-1099",
    question: "Do I need to report income if I didn't receive a 1099-K?",
    answer:
      "Yes. Even if you didn't meet the IRS thresholds for a 1099-K, you are still required to report all income from Gumroad on your tax return.",
  },
];

const TaxCenterIndex = () => {
  const { documents, available_years, selected_year } = cast<{
    documents: TaxDocument[];
    available_years: number[];
    selected_year: number | null;
  }>(usePage().props);
  const loggedInUser = useLoggedInUser();
  const [isLoading, setIsLoading] = React.useState(false);
  const [downloadingFormType, setDownloadingFormType] = React.useState<string | null>(null);

  const handleYearChange = (year: number) => {
    router.reload({
      data: { year },
      onStart: () => setIsLoading(true),
      onFinish: () => setIsLoading(false),
      onError: () => showAlert("Something went wrong. Please try again.", "error"),
    });
  };

  const handleDownload = (_e: React.MouseEvent<HTMLAnchorElement>, formType: string) => {
    setDownloadingFormType(formType);

    const handleVisibilityChange = () => {
      if (!document.hidden) {
        setDownloadingFormType(null);
        document.removeEventListener("visibilitychange", handleVisibilityChange);
      }
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
  };

  const settingsAction = loggedInUser?.policies.settings_payments_user.show ? (
    <NavigationButton href={Routes.settings_payments_path()}>
      <Icon name="gear-fill" />
      Settings
    </NavigationButton>
  ) : null;

  return (
    <>
      <PageHeader
        title="Payouts"
        actions={settingsAction ? <div className="flex gap-2">{settingsAction}</div> : undefined}
      >
        <Tabs>
          <Tab isSelected={false} asChild>
            <Link href={Routes.balance_path()}>Payouts</Link>
          </Tab>
          <Tab isSelected asChild>
            <Link href={Routes.tax_center_path()}>Taxes</Link>
          </Tab>
        </Tabs>
      </PageHeader>
      <section className="p-4 md:p-8">
        <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <h2>Tax documents</h2>
          {selected_year ? (
            <div className="flex items-center gap-3">
              <select
                aria-label="Tax year"
                disabled={isLoading}
                value={selected_year}
                onChange={(e) => handleYearChange(parseInt(e.target.value, 10))}
              >
                {available_years.map((year) => (
                  <option key={year} value={year}>
                    {year}
                  </option>
                ))}
              </select>
            </div>
          ) : null}
        </div>

        {documents.length > 0 ? (
          <div className="paragraphs">
            <Table
              aria-label="Tax documents"
              aria-live="polite"
              className={classNames(isLoading && "pointer-events-none opacity-50")}
            >
              <TableHeader>
                <TableRow>
                  <TableHead>Document</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Gross</TableHead>
                  <TableHead>Fees</TableHead>
                  <TableHead>Taxes</TableHead>
                  <TableHead>Affiliate commission</TableHead>
                  <TableHead>Net</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {documents.map((doc) => (
                  <TableRow key={doc.form_type}>
                    <TableCell data-label="Document">
                      <div className="flex items-center gap-2">
                        <span>{doc.document}</span>
                      </div>
                    </TableCell>
                    <TableCell data-label="Type">{doc.type}</TableCell>
                    <TableCell data-label="Gross">{doc.gross}</TableCell>
                    <TableCell data-label="Fees">-{doc.fees}</TableCell>
                    <TableCell data-label="Taxes">-{doc.taxes}</TableCell>
                    <TableCell data-label="Affiliate commission">-{doc.affiliate_credit}</TableCell>
                    <TableCell data-label="Net">{doc.net}</TableCell>
                    <TableCell data-label="" className="text-right">
                      <div className="flex justify-end">
                        <NavigationButton
                          small
                          className="w-full sm:w-auto"
                          href={Routes.download_tax_form_path(doc.year, doc.form_type)}
                          disabled={downloadingFormType === doc.form_type}
                          onClick={(e) => handleDownload(e, doc.form_type)}
                        >
                          {downloadingFormType === doc.form_type ? "Downloading..." : "Download"}
                        </NavigationButton>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        ) : (
          <Placeholder>
            <figure>
              <img src={taxesPlaceholder} />
            </figure>
            <h2>Let's get your tax info ready.</h2>
            <p>Your 1099-K will appear here once it's available.</p>
          </Placeholder>
        )}
      </section>

      <section className="p-4 md:p-8">
        <h2 className="mb-4">Find answers to your tax questions</h2>
        <div className="stack">
          {FAQ_ITEMS.map((item) => (
            <details key={item.id}>
              <summary>{item.question}</summary>
              <p className="text-sm">{item.answer}</p>
            </details>
          ))}
        </div>
        <p className="mt-4 text-sm text-muted">
          Need more help? Search our <a href="/help">Help Center</a>.
        </p>
      </section>
    </>
  );
};

export default TaxCenterIndex;
