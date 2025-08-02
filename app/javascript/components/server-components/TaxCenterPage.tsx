import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

type TaxDocument = {
  id: string;
  document: string;
  type: string;
  gross: number;
  fees: number;
  taxes: number;
  net: number;
  downloadUrl: string;
  isNew?: boolean;
};

type TaxService = {
  id: string;
  name: string;
  description: string;
  logo: string;
  url: string;
};

type FAQ = {
  id: string;
  question: string;
  answer: string;
};

type RelatedArticle = {
  id: string;
  title: string;
  url: string;
};

type TaxCenterData = {
  selectedYear: string;
  availableYears: string[];
  taxDocuments: TaxDocument[];
  taxServices: TaxService[];
  faqs: FAQ[];
  relatedArticles: RelatedArticle[];
};

const formatCurrency = (amount: number) => {
  return formatPriceCentsWithCurrencySymbol("usd", Math.abs(amount), {
    symbolFormat: "short",
    noCentsIfWhole: false,
  });
};

const formatNegativeCurrency = (amount: number) => {
  return `-${formatCurrency(amount)}`;
};

const TaxDocumentsTable = ({
  documents,
  onDownload,
  onDownloadAll,
}: {
  documents: TaxDocument[];
  onDownload: (document: TaxDocument) => void;
  onDownloadAll: () => void;
}) => (
  <section>
    <header
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        marginBottom: "var(--spacer-4)",
      }}
    >
      <h2>Tax documents</h2>
      <Button onClick={onDownloadAll} disabled={documents.length === 0}>
        Download all
      </Button>
    </header>
    <table>
      <thead>
        <tr>
          <th>Document</th>
          <th>Type</th>
          <th>Gross</th>
          <th>Fees</th>
          <th>Taxes</th>
          <th>Net</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>
        {documents.map((document) => (
          <tr key={document.id}>
            <td>
              <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}>
                {document.document}
                {document.isNew && (
                  <span
                    style={{
                      backgroundColor: "var(--color-primary)",
                      color: "white",
                      padding: "var(--spacer-1) var(--spacer-2)",
                      borderRadius: "var(--border-radius-2)",
                      fontSize: "var(--font-size-small)",
                    }}
                  >
                    New
                  </span>
                )}
              </div>
            </td>
            <td>{document.type}</td>
            <td>{formatCurrency(document.gross)}</td>
            <td>{formatNegativeCurrency(document.fees)}</td>
            <td>{formatNegativeCurrency(document.taxes)}</td>
            <td>{formatCurrency(document.net)}</td>
            <td>
              <Button small onClick={() => onDownload(document)}>
                Download
              </Button>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  </section>
);

const TaxServicesSection = ({ services }: { services: TaxService[] }) => (
  <section>
    <header>
      <h2>Save on your taxes</h2>
      <p>Explore ways to minimize your tax burden as your business grows.</p>
    </header>
    <div
      style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))", gap: "var(--spacer-4)" }}
    >
      {services.map((service) => (
        <div
          key={service.id}
          style={{
            border: "var(--border)",
            borderRadius: "var(--border-radius-3)",
            padding: "var(--spacer-4)",
            display: "flex",
            alignItems: "center",
            gap: "var(--spacer-3)",
          }}
        >
          <div
            style={{
              width: "48px",
              height: "48px",
              borderRadius: "var(--border-radius-2)",
              backgroundColor: "var(--color-filled)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <Icon name="building" />
          </div>
          <div style={{ flex: 1 }}>
            <h3 style={{ marginBottom: "var(--spacer-1)" }}>{service.name}</h3>
            <p style={{ fontSize: "var(--font-size-small)", color: "var(--color-text-secondary)" }}>
              {service.description}
            </p>
          </div>
          <NavigationButton small href={service.url} target="_blank" rel="noopener noreferrer">
            Visit
          </NavigationButton>
        </div>
      ))}
    </div>
  </section>
);

const FAQSection = ({ faqs }: { faqs: FAQ[] }) => {
  const [expandedFaqs, setExpandedFaqs] = React.useState<Set<string>>(new Set());

  const toggleFaq = (faqId: string) => {
    const newExpanded = new Set(expandedFaqs);
    if (newExpanded.has(faqId)) {
      newExpanded.delete(faqId);
    } else {
      newExpanded.add(faqId);
    }
    setExpandedFaqs(newExpanded);
  };

  return (
    <section>
      <header>
        <h2>FAQs</h2>
      </header>
      <div style={{ display: "grid", gap: "var(--spacer-3)" }}>
        {faqs.map((faq) => (
          <div
            key={faq.id}
            style={{
              border: "var(--border)",
              borderRadius: "var(--border-radius-3)",
            }}
          >
            <button
              onClick={() => toggleFaq(faq.id)}
              style={{
                width: "100%",
                padding: "var(--spacer-4)",
                textAlign: "left",
                border: "none",
                background: "none",
                cursor: "pointer",
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
              }}
            >
              <span>{faq.question}</span>
              <Icon name={expandedFaqs.has(faq.id) ? "outline-cheveron-up" : "outline-cheveron-down"} />
            </button>
            {expandedFaqs.has(faq.id) && (
              <div
                style={{
                  padding: "0 var(--spacer-4) var(--spacer-4)",
                  borderTop: "var(--border)",
                }}
              >
                <p>{faq.answer}</p>
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  );
};

const RelatedArticlesSection = ({ articles }: { articles: RelatedArticle[] }) => (
  <section>
    <header>
      <h2>Related articles from our Help Center</h2>
    </header>
    <div
      style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(250px, 1fr))", gap: "var(--spacer-4)" }}
    >
      {articles.map((article) => (
        <div
          key={article.id}
          style={{
            border: "var(--border)",
            borderRadius: "var(--border-radius-3)",
            padding: "var(--spacer-4)",
          }}
        >
          <h3 style={{ marginBottom: "var(--spacer-2)" }}>
            <a href={article.url} style={{ textDecoration: "none", color: "inherit" }}>
              {article.title}
            </a>
          </h3>
        </div>
      ))}
    </div>
  </section>
);

const TaxCenterPage = ({
  selectedYear,
  availableYears,
  taxDocuments,
  taxServices,
  faqs,
  relatedArticles,
}: TaxCenterData) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();

  const [currentYear, setCurrentYear] = React.useState(selectedYear);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleYearChange = async (year: string) => {
    setIsLoading(true);
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: `/payouts/taxes?year=${year}`,
      })
        .then((res) => res.json())
        .then((json) => cast<{ taxDocuments: TaxDocument[] }>(json));

      setCurrentYear(year);
      // In a real implementation, you would update the documents state here
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleDownload = async (taxDocument: TaxDocument) => {
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: taxDocument.downloadUrl,
      });

      if (response.ok) {
        const blob = await response.blob();
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `${taxDocument.document}-${currentYear}.pdf`;
        document.body.appendChild(a);
        a.click();
        window.URL.revokeObjectURL(url);
        document.body.removeChild(a);
        showAlert("Document downloaded successfully!", "success");
      }
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    }
  };

  const handleDownloadAll = async () => {
    try {
      const response = await request({
        method: "GET",
        accept: "json",
        url: `/payouts/taxes/download-all?year=${currentYear}`,
      });

      if (response.ok) {
        const blob = await response.blob();
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `tax-documents-${currentYear}.zip`;
        document.body.appendChild(a);
        a.click();
        window.URL.revokeObjectURL(url);
        document.body.removeChild(a);
        showAlert("All documents downloaded successfully!", "success");
      }
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    }
  };

  if (!loggedInUser) return null;

  const settingsAction = loggedInUser.policies.settings_payments_user.show ? (
    <NavigationButton href="/settings/payments">
      <Icon name="gear-fill" />
      Settings
    </NavigationButton>
  ) : null;

  return (
    <main>
      <header>
        <h1>Payouts</h1>
        {settingsAction && <div className="actions flex gap-2">{settingsAction}</div>}
      </header>

      <div style={{ display: "grid", gap: "var(--spacer-7)" }}>
        <div
          style={{
            display: "flex",
            gap: "var(--spacer-4)",
            borderBottom: "var(--border)",
            marginBottom: "var(--spacer-4)",
          }}
        >
          <a
            href="/payouts"
            style={{
              padding: "var(--spacer-2) var(--spacer-4)",
              textDecoration: "none",
              color: "var(--color-text-secondary)",
              borderBottom: "2px solid transparent",
            }}
          >
            Payouts
          </a>
          <a
            href="/payouts/taxes"
            style={{
              padding: "var(--spacer-2) var(--spacer-4)",
              textDecoration: "none",
              color: "var(--color-text-primary)",
              borderBottom: "2px solid var(--color-primary)",
            }}
          >
            Taxes
          </a>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-3)" }}>
          <label htmlFor="year-selector">Year:</label>
          <select
            id="year-selector"
            value={currentYear}
            onChange={(e) => handleYearChange(e.target.value)}
            disabled={isLoading}
            style={{
              padding: "var(--spacer-2) var(--spacer-3)",
              border: "var(--border)",
              borderRadius: "var(--border-radius-2)",
              backgroundColor: "var(--color-filled)",
            }}
          >
            {availableYears.map((year) => (
              <option key={year} value={year}>
                {year}
              </option>
            ))}
          </select>
        </div>

        <TaxDocumentsTable documents={taxDocuments} onDownload={handleDownload} onDownloadAll={handleDownloadAll} />

        <TaxServicesSection services={taxServices} />

        <FAQSection faqs={faqs} />

        <RelatedArticlesSection articles={relatedArticles} />
      </div>
    </main>
  );
};

export default register({ component: TaxCenterPage, propParser: createCast() });
