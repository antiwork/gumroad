# frozen_string_literal: true

class TraTinValidationService
  attr_reader :tra_tin

  def initialize(tra_tin)
    @tra_tin = tra_tin
  end

  def process
    return false if tra_tin.blank?
    tra_tin.match?(/\A\d{2}-\d{6}-[A-Z]\z/)
  end
end
