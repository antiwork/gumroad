# frozen_string_literal: true

# The seller's side of a piracy report: file one, then read and sign the notice we send.
class PiracyReportsController < Sellers::BaseController
  layout "inertia"

  before_action :set_product, only: [:new, :create]
  before_action :set_report, only: [:show, :sign]

  def new
    authorize PiracyReport

    render inertia: "PiracyReports/New", props: {
      product: { id: @product.unique_permalink, name: @product.name, url: @product.long_url },
      eligibility_errors: PiracyReports::Eligibility.new(seller: current_seller, product: @product).errors,
      reports_this_month: PiracyReport.created_this_month_count(current_seller),
      monthly_limit: PiracyReport::MONTHLY_LIMIT,
    }
  end

  def create
    authorize PiracyReport

    result = PiracyReports::CreateService.new(
      seller: current_seller,
      product: @product,
      url: params[:url].to_s,
      source: "dashboard"
    ).call

    if result.success?
      redirect_to piracy_report_path(result.report.external_id), notice: "Report received. We are reviewing the page."
    else
      redirect_to new_piracy_report_path(product_id: @product.unique_permalink), alert: result.errors.to_sentence
    end
  end

  def show
    authorize @report

    render inertia: "PiracyReports/Show", props: {
      report: report_props,
      product: { name: @report.product.name, url: @report.product.long_url },
      confirmations: PiracyReport::SIGNATURE_CONFIRMATIONS.map { |key, text| { key:, text: } },
      confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION,
    }
  end

  def sign
    authorize @report

    if @report.record_signature!(
      params[:signed_by_name], confirmations: params[:confirmations], statement_version: params[:confirmations_version], ip: request.remote_ip
    )
      redirect_to piracy_report_path(@report.external_id), notice: "Signed. We will send the notice."
    else
      redirect_to piracy_report_path(@report.external_id), alert: @report.errors.full_messages.to_sentence
    end
  end

  private
    def set_product
      @product = current_seller.links.alive.find_by(unique_permalink: params[:product_id].to_s)
      redirect_to products_path, alert: "Product not found" if @product.blank?
    end

    def set_report
      @report = PiracyReport.find_by(external_id: params[:id].to_s, seller_id: current_seller.id)
      redirect_to products_path, alert: "Report not found" if @report.blank?
    end

    def report_props
      {
        id: @report.external_id,
        state: @report.state,
        url: @report.url,
        created_at: @report.created_at.iso8601,
        # The seller signs this text. Signing appends the signature line and updates the digest.
        notice_text: @report.notice_text,
        notice_digest: @report.notice_digest,
        signed_at: @report.signed_at&.iso8601,
        signed_by_name: @report.signed_by_name,
        sent_at: @report.sent_at&.iso8601,
        counter_notice_received_on: @report.counter_notice_received_on&.iso8601,
        outcome: @report.outcome,
      }
    end
end
