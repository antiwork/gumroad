# frozen_string_literal: true

class GenerateLicensesForExistingCustomers < ActiveRecord::Migration
  def change
    # Commented out as it is taking too long to run on production.

    # Link.is_licensed.find_each do |link|
    #   CreateLicensesForExistingCustomers.perform(link.id)
    # end
  end
end
