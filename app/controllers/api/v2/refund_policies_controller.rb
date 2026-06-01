# frozen_string_literal: true

class Api::V2::RefundPoliciesController < Api::V2::BaseController
  REFUND_PERIOD_ALLOWED_VALUES = %w[none 7 14 30 183].freeze
  REFUND_PERIOD_VALUES = {
    "none" => 0,
    "7" => 7,
    "14" => 14,
    "30" => 30,
    "183" => 183,
  }.freeze
  ACCOUNT_LEVEL_REFUND_POLICY_NOT_IN_EFFECT_MESSAGE = "The account-level refund policy is not in effect for this seller."

  before_action(only: [:show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:update]) { doorkeeper_authorize! :edit_products }

  def show
    success_with_object(:refund_policy, serialized_refund_policy)
  end

  def update
    return render_response(false, message: ACCOUNT_LEVEL_REFUND_POLICY_NOT_IN_EFFECT_MESSAGE) unless current_resource_owner.account_level_refund_policy_enabled?
    return render_response(false, message: "Refund period is required.") if params[:refund_period].blank?

    refund_policy = current_resource_owner.refund_policy
    if refund_policy.update(refund_policy_params)
      success_with_object(:refund_policy, serialized_refund_policy)
    else
      render_response(false, message: refund_policy_error_message(refund_policy))
    end
  end

  private
    def refund_policy_params
      permitted_params = { max_refund_period_in_days: REFUND_PERIOD_VALUES[params[:refund_period].to_s] }
      permitted_params[:fine_print] = params[:fine_print] if params.key?(:fine_print)
      permitted_params
    end

    def refund_policy_error_message(refund_policy)
      return "Refund period must be one of: #{REFUND_PERIOD_ALLOWED_VALUES.join(', ')}." if refund_policy.errors.of_kind?(:max_refund_period_in_days, :inclusion)

      refund_policy.errors.full_messages.to_sentence
    end

    def serialized_refund_policy
      refund_policy = current_resource_owner.refund_policy
      {
        refund_period: serialized_refund_period(refund_policy),
        title: refund_policy.title,
        fine_print: refund_policy.fine_print,
        in_effect: current_resource_owner.account_level_refund_policy_enabled?,
      }
    end

    def serialized_refund_period(refund_policy)
      refund_policy.max_refund_period_in_days.zero? ? "none" : refund_policy.max_refund_period_in_days.to_s
    end
end
