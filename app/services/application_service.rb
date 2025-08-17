# frozen_string_literal: true

class ApplicationService
  include ActiveModel::Validations
  include ActiveModel::AttributeAssignment

  def self.call(*args, **kwargs)
    service = new(*args, **kwargs)
    service.call
  end

  def call
    validate!
    perform
  rescue StandardError => e
    handle_error(e)
  end

  private

  def perform
    raise NotImplementedError, "Subclasses must implement #perform"
  end

  def success(data = {})
    ServiceResult.success(data)
  end

  def failure(error_message, errors: {})
    ServiceResult.failure(error_message, errors)
  end

  def handle_error(error)
    Rails.logger.error("#{self.class.name} failed: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))

    Bugsnag.notify(error, {
      service: self.class.name,
      context: service_context
    })

    failure("An unexpected error occurred")
  end

  def service_context
    {}
  end
end
