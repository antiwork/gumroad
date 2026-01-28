# frozen_string_literal: true

class AddBacktaxAgreementIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :backtax_agreement_id, :bigint
  end
end
