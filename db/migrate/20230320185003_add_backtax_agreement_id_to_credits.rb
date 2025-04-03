# frozen_string_literal: true

class AddBacktaxAgreementIdToCredits < ActiveRecord::Migration[7.0]
  def change
    add_column :credits, :backtax_agreement_id, :bigint
  end
end
