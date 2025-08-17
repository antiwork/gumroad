# frozen_string_literal: true

class ServiceResult
  attr_reader :data, :error_message, :errors

  def initialize(success:, data: {}, error_message: nil, errors: {})
    @success = success
    @data = data
    @error_message = error_message
    @errors = errors
  end

  def self.success(data = {})
    new(success: true, data: data)
  end

  def self.failure(error_message, errors: {})
    new(success: false, error_message: error_message, errors: errors)
  end

  def success?
    @success
  end

  def failure?
    !@success
  end

  def [](key)
    data[key]
  end
end
