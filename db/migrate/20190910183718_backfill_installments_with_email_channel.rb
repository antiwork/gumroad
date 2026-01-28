# frozen_string_literal: true

class BackfillInstallmentsWithEmailChannel < ActiveRecord::Migration[4.2]
  def up
    Installment.find_in_batches do |installments|
      installments.each do |installment|
        installment.send_emails = true
        installment.save!
      end
      sleep(0.05)
    end
  end
end
