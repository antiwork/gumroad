# frozen_string_literal: true

class Exports::Payouts::Data < Exports::Payouts::Base
  def perform
    payout_data
  end
end
