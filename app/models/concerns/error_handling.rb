# frozen_string_literal: true

module ErrorHandling
  extend ActiveSupport::Concern

  private

  def handle_service_error(error, context = {})
    log_error(error, context)
    notify_error_tracking(error, context)
    format_error_response(error)
  end

  def handle_validation_error(record)
    {
      success: false,
      message: record.errors.full_messages.to_sentence,
      errors: record.errors.as_json
    }
  end

  def handle_not_found_error(resource_name = "Resource")
    {
      success: false,
      message: "#{resource_name} not found"
    }
  end

  def handle_authorization_error
    {
      success: false,
      message: "You are not authorized to perform this action"
    }
  end

  def log_error(error, context)
    Rails.logger.error("#{error.class.name}: #{error.message}")
    Rails.logger.error("Context: #{context}") if context.any?
    Rails.logger.error(error.backtrace.join("\n"))
  end

  def notify_error_tracking(error, context)
    Bugsnag.notify(error, context.merge(
      controller: self.class.name,
      action: action_name,
      user_id: current_user&.id
    ))
  end

  def format_error_response(error)
    case error
    when ActiveRecord::RecordNotFound
      handle_not_found_error
    when ActiveRecord::RecordInvalid
      handle_validation_error(error.record)
    when Pundit::NotAuthorizedError
      handle_authorization_error
    when Purchase::PurchaseInvalid
      { success: false, message: error.message }
    else
      { success: false, message: "An unexpected error occurred" }
    end
  end
end
