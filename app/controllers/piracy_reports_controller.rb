# frozen_string_literal: true

# The seller's side of a piracy report: file one, then read and sign the notice we send.
class PiracyReportsController < Sellers::BaseController
  layout "inertia"

  before_action :set_product, only: [:new, :create]
  before_action :set_report, only: [:show, :sign, :cancel]

  def index
    authorize PiracyReport

    # MONTHLY_LIMIT keeps this list short, so it needs no pages.
    reports = PiracyReport.where(seller_id: current_seller.id).includes(:product).order(id: :desc)
    render inertia: "PiracyReports/Index", props: {
      archived_tab_visible: current_seller.archived_products_count > 0,
      can_report: policy(PiracyReport).new?,
      reports: reports.map do |report|
        { id: report.external_id, product_name: report.product.name, url: report.url, state: report.state, outcome: report.outcome, updated_at: report.updated_at.iso8601 }
      end,
    }
  end

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

  # Takes the row lock the send job claims under, so a cancel and a send cannot both happen.
  def cancel
    authorize @report

    # A second tab may confirm after the first one cancelled, so an already-cancelled report is a success.
    cancelled = @report.with_lock { @report.cancelled? || (@report.can_cancel? && @report.cancel!) }
    if cancelled
      redirect_to piracy_report_path(@report.external_id), notice: "Report cancelled. Nothing was sent."
    elsif @report.declined?
      redirect_to piracy_report_path(@report.external_id), alert: "We did not send this report, so there is nothing to cancel."
    else
      redirect_to piracy_report_path(@report.external_id), alert: "This notice was already sent, so the report cannot be cancelled."
    end
  end

  private
    def set_product
      @product = current_seller.links.alive.find_by(unique_permalink: params[:product_id].to_s)
      redirect_to products_path, alert: "Product not found" if @product.blank?
    end

    # A counter-notice clears resolved_at, so a reopened report shows no earlier outcome.
    def report_history
      [
        [:filed, @report.created_at],
        [@report.declined? ? :declined : :confirmed, @report.screening_verdict.in?(%w[pass fail]) && !@report.screening? ? @report.screened_at : nil],
        [:signed, @report.signed_at],
        [:sent, @report.sent_at],
        [:delivered, @report.delivered_at],
        [:counter_notice, @report.counter_notice_received_on],
        [:resolved, @report.resolved? ? @report.resolved_at : nil],
        [:closed, @report.cancelled? ? @report.updated_at : nil],
      ].filter_map { |event, at| { event:, at: at.iso8601 } if at }
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
        can_cancel: @report.can_cancel?,
        sent_at: @report.sent_at&.iso8601,
        recipient_name: @report.recipient_name,
        restoration_window: @report.restoration_window&.map(&:iso8601),
        # A person, not the agent, decides these, so the usual screening time does not apply.
        waiting_on_person: @report.screening? && @report.screening_verdict.present?,
        history: report_history,
        counter_notice_received_on: @report.counter_notice_received_on&.iso8601,
        outcome: @report.outcome,
      }
    end
end
