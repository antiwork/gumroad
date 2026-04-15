# frozen_string_literal: true

class Exports::TaxSummary::Payable < Exports::TaxSummary::Base
  # When we want to use this to build the bigger report,
  # we pass as_csv: false to just fetch row to be added to bigger CSV
  # Otherwise the default behaviour to generate this report for single
  # user, when we want to file for corrections for some user.
  def perform(as_csv: true)
    unless compliance_info&.has_completed_compliance_info?
      Rails.logger.info("Failed to export tax summary for user #{@user.id}")
      return nil
    end
    data = payouts_summary
    return nil unless data && data[:total_transaction_cents] > 0
    if as_csv
      CsvSafe.generate do |csv|
        csv << payable_headers

        row = build_payable_summary(data)
        csv << row if row
      end
    else
      build_payable_summary(data)
    end
  end

  # Header references: https://payable.com/taxes/part-2-how-to-set-up-a-full-form-import-1099-misc-1099-k
  def payable_headers
    ["Payable Worker ID",
     "External Worker ID",
     "Stripe ID",
     "Display Name", "First Name", "Last Name", "Business Name",
     "Email",
     "Address Line 1", "Address Line 2", "City", "Region", "Postal Code", "Country",
     "Business Type",
     "SSN", "EIN",
     "Filer Is",
     "Transactions Reported Are",
     "PSE's Name", "PSE's Phone",
     "Box 1a - Gross Amount of Transactions", "Box 1b - Card Not Present Transactions",
     "Box 2 - Merchant Category Code",
     "Box 3 - Number of Payment Transactions",
     "Box 4 - Federal Income Tax Withheld",
     "Box 5a - Jan", "Box 5b - Feb", "Box 5c - Mar", "Box 5d - Apr", "Box 5e - May", "Box 5f - Jun", "Box 5g - Jul", "Box 5h - Aug", "Box 5i - Sep", "Box 5j - Oct", "Box 5k - Nov", "Box 5l - Dec",
     "Box 6 - State Abbreviation", "Box 6 (Other State) - Other State Abbreviation",
     "Box 7 - Filer's State ID", "Box 7 (Other State) - Filer's Other State ID",
     "Box 8 - State Tax Withheld", "Box 8 (Other State) - Other State Tax Withheld"]
  end

  private
    # See https://payable.com/taxes/part-2-how-to-set-up-a-full-form-import-1099-misc-1099-k
    # for how we get these values
    def build_payable_summary(data)
      row = [nil, # "Payable Worker ID": We don't have this value and should be null # [0]
             # Payable uses this to match users the next time we upload
             @user.external_id, # [1]
             # "Stripe ID",
             stripe_id, # [2]
             # "Display Name", "First Name", "Last Name", "Business Name",
             compliance_info.first_and_last_name, compliance_info.first_name, compliance_info.last_name, compliance_info.legal_entity_name, # [3, 4, 5, 6]
             # Email
             @user.email, # [7]
             # "Address Line 1", "Address Line 2", "City", "Region", "Postal Code", "Country",
             compliance_info.legal_entity_street_address, nil, compliance_info.legal_entity_city, compliance_info.legal_entity_state_code, compliance_info.legal_entity_zip_code, compliance_info.legal_entity_country_code, # [8, 9, 10, 11, 12, 13]
             # "Business Type",
             compliance_info.legal_entity_payable_business_type, # [14]
             # "SSN", "EIN",
             personal_tax_id.presence, business_tax_id.presence, # [15, 16]
             # "Filer Is",
             "EPF Other", # [17]
             # "Transactions Reported Are",
             "Third Party Network", # [18]
             # "PSE's Name", "PSE's Phone",
             "Gumroad", "(650) 204-3486", # [19, 20]
             # Box 1a -  Gross Amount of Transactions
             (data[:total_transaction_cents] / 100.0), # [21]
             # Box 1b -  Card Not Present Transactions
             nil, # [22]
             # "Box 2 - Merchant Category Code", this is empty on payable
             nil, # [23]
             # Box 3 -  Number of Payment Transactions
             # The total count of all payment transactions for the Payee in the given tax year
             data[:transactions_count], # [24]
             # "Box 4 - Federal Income Tax Withheld", this is empty on payable
             nil] # [25]

      row.concat(monthly_summary_for(data))

      row.concat([ # "Box 6 - State Abbreviation",
                   compliance_info.legal_entity_state_code,
                   # "Box 6 (Other State) - Other State Abbreviation"
                   nil,
                   # "Box 7 - Filer's State ID",
                   nil,
                   # "Box 7 (Other State) - Filer's Other State ID",
                   nil,
                   # "Box 8 - State Tax Withheld", this, its zero on payable.
                   nil,
                   # "Box 8 (Other State) - Other State Tax Withheld"
                   nil])
      row
    end

    def compliance_info
      @compliance_info ||= @user.alive_user_compliance_info
    end

    def stripe_id
      stripe_merchant_account = @user.merchant_accounts.alive.stripe.first
      stripe_merchant_account.present? ? stripe_merchant_account.charge_processor_merchant_id : nil
    end

    def personal_tax_id
      compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
    end

    def business_tax_id
      compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")) if compliance_info.is_business
    end

    def monthly_summary_for(data)
      monthly_summary = []
      data[:transaction_cents_by_month].each do |index, amount_cents|
        monthly_summary[index] = amount_cents / 100.0
      end
      monthly_summary
    end
end
