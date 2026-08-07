# frozen_string_literal: true

class Api::V2::Workflows::EmailsController < Api::V2::BaseController
  include InstallmentRuleHelper

  DELAY_UNITS = [InstallmentRule::HOUR, InstallmentRule::DAY, InstallmentRule::WEEK, InstallmentRule::MONTH].freeze
  MAX_DELAY_SECONDS = (2**31) - 1
  WRITE_PARAMS = %i[subject body delay_amount delay_unit].freeze
  WORKFLOW_STATE_PARAMS = %i[publish unpublish draft state published_at save_action_name send_to_past_customers].freeze

  before_action { doorkeeper_authorize! :edit_emails }
  before_action :fetch_workflow
  before_action :fetch_email, only: :update

  def create
    return render_bad_request("Emails cannot be added to abandoned cart workflows.") if @workflow.abandoned_cart_type?
    return unless valid_write_params?(require_all: true)

    save_email
  end

  def update
    return unless valid_write_params?(require_all: false)

    save_email(@email)
  end

  private
    def current_seller
      current_resource_owner
    end

    def fetch_workflow
      @workflow = current_seller.workflows.alive.find_by_external_id(params[:workflow_id])
      error_with_object(:workflow, nil) if @workflow.nil?
    end

    def fetch_email
      @email = @workflow.installments.alive.find_by_external_id(params[:email_id])
      error_with_object(:email, nil) if @email.nil?
    end

    def save_email(email = nil)
      service = Workflow::SaveInstallmentsService.new(
        seller: current_seller,
        params: service_params(email),
        workflow: @workflow,
        preview_email_recipient: current_seller,
        replace_all: false
      )
      success, errors = service.process

      if success
        saved_email = service.saved_installments.sole
        email_props = Api::WorkflowPresenter.new(workflow: @workflow).email_props(saved_email, include_analytics: false)
        render_response(true, email: email_props)
      else
        render_bad_request(errors.full_messages.first)
      end
    end

    def service_params(email)
      installment_params = ActionController::Parameters.new
      installment_params[:id] = email.external_id if email.present?
      installment_params[:name] = params[:subject] if params.key?(:subject)
      installment_params[:message] = params[:body] if params.key?(:body)
      if params.key?(:delay_amount)
        installment_params[:time_duration] = parsed_delay_amount
        installment_params[:time_period] = params[:delay_unit]
      end

      ActionController::Parameters.new(
        save_action_name: Workflow::SAVE_ACTION,
        installments: [installment_params]
      )
    end

    def valid_write_params?(require_all:)
      state_param = WORKFLOW_STATE_PARAMS.find { params.key?(_1) }
      return render_bad_request("#{state_param} cannot be changed through this endpoint.") if state_param

      supplied_write_params = WRITE_PARAMS.select { params.key?(_1) }
      if require_all
        missing_param = (WRITE_PARAMS - supplied_write_params).first
        return render_bad_request("#{missing_param} is required.") if missing_param
      elsif supplied_write_params.empty?
        return render_bad_request("Provide at least one of: subject, body, delay_amount, or delay_unit.")
      end

      if params.key?(:subject) && (!params[:subject].is_a?(String) || params[:subject].strip.empty?)
        return render_bad_request("subject must be a non-empty string.")
      end
      if params.key?(:body) && !params[:body].is_a?(String)
        return render_bad_request("body must be a string.")
      end

      delay_params = %i[delay_amount delay_unit].select { params.key?(_1) }
      return true if delay_params.empty?
      return render_bad_request("delay cannot be changed for abandoned cart workflows.") if @workflow.abandoned_cart_type?
      return render_bad_request("delay_amount and delay_unit must be provided together.") if delay_params.size != 2

      amount = parsed_delay_amount
      return render_bad_request("delay_amount must be a non-negative integer.") if amount.nil? || amount.negative?
      return render_bad_request("delay_unit must be one of: #{DELAY_UNITS.join(', ')}.") if DELAY_UNITS.exclude?(params[:delay_unit])
      return render_bad_request("delay is too large.") if convert_to_seconds(amount, params[:delay_unit]).to_i > MAX_DELAY_SECONDS

      true
    end

    def parsed_delay_amount
      value = params[:delay_amount]
      return value if value.is_a?(Integer)
      return unless value.is_a?(String) && value.match?(/\A-?\d+\z/)

      Integer(value, 10)
    end

    def render_bad_request(message)
      error_400(message)
      false
    end
end
