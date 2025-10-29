import stonksLogo from "images/brands/stonks.svg";
import taxesPlaceholder from "images/placeholders/taxes.png";
import * as React from "react";

import { getTaxDocuments, TaxDocument } from "$app/data/tax_center";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useClientAlert } from "$app/components/ClientAlertProvider";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PageHeader } from "$app/components/ui/PageHeader";
import Placeholder from "$app/components/ui/Placeholder";
import { Tab, Tabs } from "$app/components/ui/Tabs";

const TAX_SAVING_SUGGESTIONS: {
  id: string;
  title: string;
  description: string;
  icon: string;
  avgRefund?: string;
  link: string;
}[] = [
  {
    id: "1",
    title: "stonks.com",
    description: "Helps creators register as a business and unlock major tax deductions. Avg refund: $8,200.",
    icon: "stonks",
    avgRefund: "$8,200",
    link: "https://stonks.com?utm_source=gumroad",
  },
];

const FAQ_ITEMS: {
  id: string;
  question: string;
  answer?: React.ReactNode;
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

export type TaxCenterPageProps = {
  documents: TaxDocument[];
  available_years: number[];
  selected_year: number;
}

const TaxCenterPage = ({
  documents: initialDocuments,
  available_years: initialAvailableYears,
  selected_year: initialSelectedYear,
}: TaxCenterPageProps) => {
  const loggedInUser = useLoggedInUser();
  const { showAlert } = useClientAlert();
  const [isLoading, setIsLoading] = React.useState(false);
  const [documents, setDocuments] = React.useState<TaxDocument[]>(initialDocuments);
  const [availableYears, setAvailableYears] = React.useState<number[]>(initialAvailableYears);
  const [selectedYear, setSelectedYear] = React.useState<number>(initialSelectedYear);
  const [downloadingFormType, setDownloadingFormType] = React.useState<string | null>(null);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const loadTaxDocuments = async (year: number) => {
    try {
      activeRequest.current?.cancel();
      setIsLoading(true);
      const request = getTaxDocuments(year);
      activeRequest.current = request;

      const data = await request.response;
      setDocuments(data.documents);
      setAvailableYears(data.available_years);
      setSelectedYear(data.selected_year);
      setIsLoading(false);
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert("Something went wrong. Please try again.", "error");
      setIsLoading(false);
    }
  };

  const handleYearChange = (year: number) => {
    void loadTaxDocuments(year);
    window.history.replaceState(null, "", `${Routes.tax_center_path()}?year=${year}`);
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
          <Tab href={Routes.balance_path()} isSelected={false}>
            Payouts
          </Tab>
          <Tab href={Routes.tax_center_path()} isSelected>
            Taxes
          </Tab>
        </Tabs>
      </PageHeader>
      <section className="p-4 md:p-8">
        <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <h2>Tax documents</h2>
          {availableYears.length > 0 && (
            <div className="flex items-center gap-3">
              <select
                disabled={isLoading}
                value={selectedYear}
                onChange={(e) => handleYearChange(parseInt(e.target.value, 10))}
              >
                {availableYears.map((year) => (
                  <option key={year} value={year}>
                    {year}
                  </option>
                ))}
              </select>
            </div>
          )}
        </div>

        {documents.length > 0 ? (
          <div className="paragraphs">
            <table aria-live="polite" aria-busy={isLoading}>
              <thead>
                <tr>
                  <th>Document</th>
                  <th>Type</th>
                  <th>Gross</th>
                  <th>Fees</th>
                  <th>Taxes</th>
                  <th>Affiliate Commission</th>
                  <th>Net</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {documents.map((doc) => (
                  <tr key={doc.form_type}>
                    <td data-label="Document">
                      <div className="flex items-center gap-2">
                        <span>{doc.document}</span>
                      </div>
                    </td>
                    <td data-label="Type">{doc.type}</td>
                    <td data-label="Gross">{doc.gross}</td>
                    <td data-label="Fees">-{doc.fees}</td>
                    <td data-label="Taxes">-{doc.taxes}</td>
                    <td data-label="Affiliate Commission">-{doc.affiliate_credit}</td>
                    <td data-label="Net">{doc.net}</td>
                    <td data-label="" className="text-right">
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
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
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
        <h2 className="mb-4">Save on your taxes</h2>
        <div className="radio-buttons grid-cols-1" role="radiogroup">
          {TAX_SAVING_SUGGESTIONS.map((suggestion) => (
            <Button
              key={suggestion.id}
              className="vertical !justify-start"
              color="filled"
              data-suggestion={suggestion.id}
              onClick={() => {
                window.open(suggestion.link, "_blank", "noopener,noreferrer");
              }}
            >
              <div className="flex w-full items-center gap-4">
                <div
                  className="flex h-16 w-16 flex-shrink-0 items-center justify-center rounded"
                  style={{
                    backgroundColor: "#101241",
                  }}
                >
                  <img src={stonksLogo} alt="Stonks" className="h-6 w-6" />
                </div>
                <div className="min-w-0 flex-1 space-y-1 text-left">
                  <h4 className="text-lg leading-tight font-semibold">{suggestion.title}</h4>
                  <p className="text-sm opacity-80">{suggestion.description}</p>
                </div>
              </div>
            </Button>
          ))}
        </div>
      </section>

      <section className="p-4 md:p-8">
        <h2 className="mb-4">Find answers to your tax questions</h2>
        <div className="stack">
          {FAQ_ITEMS.map((item) => (
            <details key={item.id}>
              <summary>{item.question}</summary>
              {!!item.answer && <p className="text-sm">{item.answer}</p>}
            </details>
          ))}
        </div>
        <p className="text-muted mt-4 text-sm">
          Need more help? Search our <a href="/help">Help Center</a>.
        </p>
      </section>
    </>
  );
};

export default TaxCenterPage;
