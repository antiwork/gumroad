# frozen_string_literal: true

class TrnValidationService
  attr_reader :trn

  def initialize(trn)
    @trn = trn
  end

  def process
    return false if trn.blank?
    trn.length == 15
  end
end
