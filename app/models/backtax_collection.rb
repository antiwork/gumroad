# frozen_string_literal: true

class BacktaxCollection < ApplicationRecord
  belongs_to :user
  belongs_to :backtax_agreement
end
