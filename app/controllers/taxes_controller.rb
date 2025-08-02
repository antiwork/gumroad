# frozen_string_literal: true

class TaxesController < Sellers::BaseController
  include CurrencyHelper
  include Pagy::Backend

  before_action :set_body_id_as_app
  before_action :set_on_balance_page

  def index
    authorize :balance

    @title = "Payouts"
    @selected_year = params[:year]&.to_i || Time.current.year
    @available_years = available_years_with_tax_data
    @tax_documents = fetch_tax_documents(@selected_year)
    @tax_services = fetch_tax_services
    @faqs = fetch_faqs
    @related_articles = fetch_related_articles

    @tax_center_props = {
      selectedYear: @selected_year.to_s,
      availableYears: @available_years.map(&:to_s),
      taxDocuments: @tax_documents,
      taxServices: @tax_services,
      faqs: @faqs,
      relatedArticles: @related_articles,
    }
  end

  def download_document
    authorize :balance, :index?

    document_id = params[:document_id]
    year = params[:year]&.to_i || Time.current.year

    tax_document = find_tax_document(document_id, year)
    return head :not_found unless tax_document

    download_url = generate_document_download_url(tax_document, year)
    redirect_to download_url, allow_other_host: true
  end

  def download_all
    authorize :balance, :index?

    year = params[:year]&.to_i || Time.current.year
    documents = fetch_tax_documents(year)

    return head :not_found if documents.empty?

    download_url = generate_all_documents_download_url(year)
    redirect_to download_url, allow_other_host: true
  end

  def reseller_certificate
    authorize :balance, :index?

    download_url = generate_reseller_certificate_url
    redirect_to download_url, allow_other_host: true
  end

  private
    def set_on_balance_page
      @on_balance_page = true
    end

    def available_years_with_tax_data
      current_seller.payments
        .completed
        .displayable
        .select("EXTRACT(YEAR FROM created_at) AS year")
        .distinct
        .order(year: :desc)
        .map(&:year)
        .map(&:to_i)
        .presence || [Time.current.year]
    end

    def fetch_tax_documents(year)
      documents = []

      # 1099-K form
      if has_1099k_for_year?(year)
        documents << {
          id: "1099k-#{year}",
          document: "1099-K",
          type: "IRS form",
          gross: fetch_gross_amount_for_year(year),
          fees: -fetch_fees_for_year(year),
          taxes: -fetch_taxes_for_year(year),
          net: fetch_net_amount_for_year(year),
          downloadUrl: "/payouts/taxes/download-document?document_id=1099k&year=#{year}",
          isNew: year == Time.current.year,
        }
      end

      # Quarterly earning summaries
      (1..4).each do |quarter|
        if has_quarterly_data?(year, quarter)
          documents << {
            id: "q#{quarter}-#{year}",
            document: "Q#{quarter} Earning summary",
            type: "Report",
            gross: fetch_quarterly_gross(year, quarter),
            fees: -fetch_quarterly_fees(year, quarter),
            taxes: -fetch_quarterly_taxes(year, quarter),
            net: fetch_quarterly_net(year, quarter),
            downloadUrl: "/payouts/taxes/download-document?document_id=q#{quarter}&year=#{year}",
          }
        end
      end

      documents
    end

    def fetch_tax_services
      [
        {
          id: "stonks",
          name: "stonks.com",
          description: "Helps creators register as a business and unlock major tax deductions. Avg refund: $8,200.",
          logo: "stonks-logo",
          url: "https://stonks.com",
        },
        {
          id: "kick",
          name: "kick.co",
          description: "Handles your bookkeeping automatically, so you're always tax-ready. Built for creators.",
          logo: "kick-logo",
          url: "https://kick.co",
        },
      ]
    end

    def fetch_faqs
      [
        {
          id: "why-1099k",
          question: "Why did I receive a 1099-K?",
          answer: "You received a 1099-K because your gross sales exceeded the reporting threshold for the tax year. This form reports the total amount of payments processed on your behalf by Gumroad.",
        },
        {
          id: "gross-sales-calculation",
          question: "How is the 'Gross Sales' amount on my 1099-K calculated?",
          answer: "The gross sales amount is the total of all payments processed on your behalf by Gumroad for the calendar year, before any fees, refunds, or adjustments. This is the amount reported to the IRS.",
        },
        {
          id: "gumroad-fees-deduction",
          question: "Where can I find my Gumroad fees to deduct on my tax return?",
          answer: "Your Gumroad fees are automatically calculated and shown in the quarterly earning summaries. You can deduct these fees as business expenses on your tax return.",
        },
        {
          id: "report-income-no-1099k",
          question: "Do I need to report income if I didn't receive a 1099-K?",
          answer: "Yes, you must report all income regardless of whether you received a 1099-K. The 1099-K is just a reporting form - you are responsible for reporting all your income to the IRS.",
        },
      ]
    end

    def fetch_related_articles
      [
        {
          id: "estimate-quarterly-taxes",
          title: "How to estimate quarterly taxes",
          url: "/help/quarterly-taxes",
        },
        {
          id: "earnings-summaries-accountant",
          title: "Using earnings summaries with your accountant",
          url: "/help/earnings-summaries",
        },
        {
          id: "tax-deductions-creators",
          title: "Tax deductions for creators",
          url: "/help/tax-deductions",
        },
      ]
    end

    def has_1099k_for_year?(year)
      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year).all_year)
        .sum(:amount_cents) >= 600_00 # $600 threshold
    end

    def has_quarterly_data?(year, quarter)
      start_month = (quarter - 1) * 3 + 1
      end_month = quarter * 3

      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year, start_month, 1)..Time.zone.local(year, end_month, -1))
        .exists?
    end

    def fetch_gross_amount_for_year(year)
      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year).all_year)
        .sum(:amount_cents)
    end

    def fetch_fees_for_year(year)
      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year).all_year)
        .sum(:gumroad_fee_cents)
    end

    def fetch_taxes_for_year(year)
      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year).all_year)
        .sum(:sales_tax_cents)
    end

    def fetch_net_amount_for_year(year)
      fetch_gross_amount_for_year(year) - fetch_fees_for_year(year) - fetch_taxes_for_year(year)
    end

    def fetch_quarterly_gross(year, quarter)
      start_month = (quarter - 1) * 3 + 1
      end_month = quarter * 3

      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year, start_month, 1)..Time.zone.local(year, end_month, -1))
        .sum(:amount_cents)
    end

    def fetch_quarterly_fees(year, quarter)
      start_month = (quarter - 1) * 3 + 1
      end_month = quarter * 3

      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year, start_month, 1)..Time.zone.local(year, end_month, -1))
        .sum(:gumroad_fee_cents)
    end

    def fetch_quarterly_taxes(year, quarter)
      start_month = (quarter - 1) * 3 + 1
      end_month = quarter * 3

      current_seller.payments
        .completed
        .displayable
        .where(created_at: Time.zone.local(year, start_month, 1)..Time.zone.local(year, end_month, -1))
        .sum(:sales_tax_cents)
    end

    def fetch_quarterly_net(year, quarter)
      fetch_quarterly_gross(year, quarter) - fetch_quarterly_fees(year, quarter) - fetch_quarterly_taxes(year, quarter)
    end

    def find_tax_document(document_id, year)
      case document_id
      when "1099k"
        return nil unless has_1099k_for_year?(year)
        {
          id: "1099k-#{year}",
          document: "1099-K",
          type: "IRS form",
          gross: fetch_gross_amount_for_year(year),
          fees: -fetch_fees_for_year(year),
          taxes: -fetch_taxes_for_year(year),
          net: fetch_net_amount_for_year(year),
        }
      when /^q(\d)$/
        quarter = $1.to_i
        return nil unless has_quarterly_data?(year, quarter)
        {
          id: "q#{quarter}-#{year}",
          document: "Q#{quarter} Earning summary",
          type: "Report",
          gross: fetch_quarterly_gross(year, quarter),
          fees: -fetch_quarterly_fees(year, quarter),
          taxes: -fetch_quarterly_taxes(year, quarter),
          net: fetch_quarterly_net(year, quarter),
        }
      else
        nil
      end
    end

    def generate_document_download_url(document, year)
      case document[:document]
      when "1099-K"
        current_seller.tax_form_1099_download_url(year: year) || "/payouts/taxes/reseller-certificate"
      when /Q\d Earning summary/
        "/api/download/#{document[:id].downcase}-#{year}.pdf"
      else
        "/payouts/taxes/reseller-certificate"
      end
    end

    def generate_all_documents_download_url(year)
      "/api/download/tax-documents-#{year}.zip"
    end

    def generate_reseller_certificate_url
      "/api/download/reseller-certificate.pdf"
    end
end
