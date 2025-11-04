# frozen_string_literal: true

class Admin::Search::BaseService
  class InvalidDateError < StandardError; end

  include ActiveModel::Validations

  attr_reader :search_attributes
  attr_reader :transaction_date
  attr_reader :formatted_transaction_date

  validate :validate_transaction_date_format

  def initialize(**search_attributes)
    @search_attributes = search_attributes
    @transaction_date = search_attributes[:transaction_date]
  end

  def perform
    valid?
    if errors[:transaction_date].any?
      raise InvalidDateError, "transaction_date must use YYYY-MM-DD format."
    end
    return empty_result unless valid?
    search
  end

  protected
    def empty_result
      raise NotImplementedError, "must be overriden in subclass"
    end

    def search
      raise NotImplementedError, "must be overriden in subclass"
    end

    def card_visual_sql_finder(last_4)
      [
        (["card_visual = ?"] * ChargeableVisual::LENGTH_TO_FORMAT.size).join(" OR "),
        *ChargeableVisual::LENGTH_TO_FORMAT.values.map { |visual_format| format(visual_format, last_4) }
      ]
    end

  private
    def validate_transaction_date_format
      return if transaction_date.blank?
      @formatted_transaction_date = Date.strptime(transaction_date, "%Y-%m-%d").in_time_zone
    rescue ArgumentError
      errors.add(:transaction_date, "must use YYYY-MM-DD format.")
    end
end
