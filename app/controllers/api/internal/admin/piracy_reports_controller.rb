# frozen_string_literal: true

class Api::Internal::Admin::PiracyReportsController < Api::Internal::Admin::BaseController
  self.required_token_scope = AdminApiToken::PIRACY_SCOPE

  MAX_LIST_RESULTS = 100
  MAX_PRODUCT_FILES = 50
  MAX_DESCRIPTION_LENGTH = 2000
  MAX_RESOLUTION_LENGTH = 32
  SCREEN_PARAM_KEYS = %w[verdict checks].freeze

  # Params are read as strings so a nested value like state[x]=y cannot reach a query as a hash.
  before_action :find_report_or_render, only: %i[show start_screening screen send_notice counter_notice resolve]

  def index
    reports = PiracyReport.includes(:seller, :product).order(:id)
    reports = reports.where(state: params[:state].to_s) if params[:state].present?

    if params[:user_id].present?
      user = User.find_by(external_id: params[:user_id].to_s)
      return render json: { success: false, message: "User not found" }, status: :not_found if user.blank?

      reports = reports.where(seller_id: user.id)
    end

    if params[:after].present?
      after = PiracyReport.find_by(external_id: params[:after].to_s)
      return render json: { success: false, message: "Piracy report not found" }, status: :not_found if after.blank?

      reports = reports.where(id: (after.id + 1)..)
    end

    if params[:updated_before].present?
      updated_before = parse_time(params[:updated_before])
      return render json: { success: false, message: "updated_before must be a timestamp" }, status: :bad_request if updated_before.nil?

      reports = reports.where(updated_at: ...updated_before)
    end

    render json: { success: true, reports: reports.limit(list_limit).map { serialize_summary(_1) } }
  end

  def show
    render json: { success: true, report: serialize_detail(@report) }
  end

  def create
    user = find_internal_admin_user_for_write_or_render
    return unless user

    product = user.links.alive.find_by_external_id(params[:product_id].to_s)
    return render json: { success: false, message: "Product not found" }, status: :not_found if product.blank?

    record_admin_write(action: "piracy_reports.create", target: user) do
      result = PiracyReports::CreateService.new(
        seller: user, product:, url: params[:url], source: "support", ticket_url: params[:ticket_url]
      ).call

      if result.success?
        render json: { success: true, report: serialize_summary(result.report) }, status: :created
      else
        render json: { success: false, message: result.errors.to_sentence, errors: result.errors }, status: :unprocessable_entity
      end
    end
  end

  # The rescue sits inside the audited block so the audit row records the 422 the client sees.
  def start_screening
    record_admin_write(action: "piracy_reports.start_screening", target: @report) do
      @report.with_lock { @report.start_screening! }
      render json: { success: true, report: serialize_summary(@report) }
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  def screen
    record_admin_write(action: "piracy_reports.screen", target: @report) do
      result = PiracyReports::ScreenService.new(
        report: @report, params: params.to_unsafe_h.slice(*SCREEN_PARAM_KEYS)
      ).call

      if result.success?
        render json: { success: true, report: serialize_detail(@report) }
      else
        render json: { success: false, message: result.errors.to_sentence, errors: result.errors }, status: :unprocessable_entity
      end
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  # Sends the signed notice. The gate is on the record, so this cannot mail text the seller did not sign.
  def send_notice
    record_admin_write(action: "piracy_reports.send_notice", target: @report) do
      result = PiracyReports::SendService.new(report: @report).call

      if result.success?
        render json: { success: true, report: serialize_detail(result.report) }
      else
        render json: { success: false, message: result.errors.to_sentence, errors: result.errors }, status: :unprocessable_entity
      end
    end
  end

  # The host's receipt date starts the restoration clock, so it is required rather than defaulted
  # to now: a reply recorded days after it arrived would otherwise start the seller's window late.
  def counter_notice
    return render json: { success: false, message: "received_at is required" }, status: :bad_request if params[:received_at].blank?

    received_at = parse_time(params[:received_at])
    return render json: { success: false, message: "received_at must be a timestamp" }, status: :bad_request if received_at.nil?

    record_admin_write(action: "piracy_reports.counter_notice", target: @report) do
      result = PiracyReports::CounterNoticeService.new(
        report: @report, body: params[:body], received_at:
      ).call

      if result.success?
        render json: { success: true, report: serialize_detail(result.report) }
      else
        render json: { success: false, message: result.errors.to_sentence, errors: result.errors }, status: :unprocessable_entity
      end
    end
  end

  # The outcome is checked before the transition, because a resolved report takes no further writes:
  # an empty or over-long value would otherwise close the report with nothing usable on it.
  def resolve
    record_admin_write(action: "piracy_reports.resolve", target: @report) do
      if (error = resolution_error)
        render json: { success: false, message: error }, status: :unprocessable_entity
      else
        @report.with_lock do
          @report.assign_attributes(resolved_at: Time.current, resolution: params[:resolution].to_s.strip)
          @report.resolve!
        end
        render json: { success: true, report: serialize_detail(@report) }
      end
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  private
    def resolution_error
      resolution = params[:resolution].to_s.strip
      return "resolution is required" if resolution.blank?
      return "resolution must be #{MAX_RESOLUTION_LENGTH} characters or fewer" if resolution.length > MAX_RESOLUTION_LENGTH

      nil
    end

    def find_report_or_render
      @report = PiracyReport.find_by(external_id: params[:id].to_s)
      render json: { success: false, message: "Piracy report not found" }, status: :not_found if @report.blank?
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def list_limit
      requested = params[:limit].to_s.to_i
      requested.positive? ? [requested, MAX_LIST_RESULTS].min : MAX_LIST_RESULTS
    end

    def serialize_summary(report)
      {
        report_id: report.external_id,
        state: report.state,
        # A pass the registry cannot route. Carried so the queue is visible without naming the contact.
        blocked_on_recipient: report.blocked_on_recipient?,
        needs_review: report.needs_review?,
        source: report.source,
        url: report.url,
        user_id: report.seller.external_id,
        product_id: report.product.external_id,
        ticket_url: report.ticket_url,
        created_at: report.created_at.as_json,
        updated_at: report.updated_at.as_json
      }
    end

    def serialize_detail(report)
      serialize_summary(report).merge(
        seller_name: report.seller.name.presence,
        product: serialize_product_facts(report.product),
        eligibility_errors: PiracyReports::Eligibility.new(seller: report.seller, product: report.product).errors,
        screening_verdict: report.screening_verdict,
        screening_checks: report.screening_checks,
        screened_at: report.screened_at.as_json,
        recipient: { name: report.recipient_name, email: report.recipient_email, source_url: report.recipient_source_url },
        # The notice holds the seller's legal name and email; the agent gets only its digest.
        notice_digest: report.notice_digest,
        sent_at: report.sent_at.as_json,
        sent_to_email: report.sent_to_email,
        delivery_status: report.delivery_status,
        counter_notice_received_at: report.counter_notice_received_at.as_json,
        counter_notice_forwarded_at: report.counter_notice_forwarded_at.as_json,
        resolved_at: report.resolved_at.as_json,
        resolution: report.resolution
      )
    end

    def serialize_product_facts(product)
      successful_sales = Purchase.successful.where(link_id: product.id)
      {
        name: product.name,
        url: product.long_url,
        description: ActionController::Base.helpers.strip_tags(product.description.to_s).squish.truncate(MAX_DESCRIPTION_LENGTH),
        created_at: product.created_at.as_json,
        files: product.product_files.alive.limit(MAX_PRODUCT_FILES).map do |file|
          { name: file.name_displayable, filetype: file.filetype, size: file.size }
        end,
        successful_sales_count: successful_sales.count,
        first_sale_at: successful_sales.minimum(:created_at).as_json
      }
    end
end
