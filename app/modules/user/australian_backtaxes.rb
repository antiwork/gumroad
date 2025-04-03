# frozen_string_literal: true

##
# A collection of methods to help with backtax calculations
##

class User
  module AustralianBacktaxes
    def opted_in_to_australia_backtaxes?
      australia_backtax_agreement.present?
    end

    def au_backtax_agreement_date
      australia_backtax_agreement&.created_at
    end

    def paid_for_austalia_backtaxes?
      australia_backtax_agreement&.credit.present?
    end

    def date_paid_australia_backtaxes
      australia_backtax_agreement&.credit&.created_at&.strftime("%B %-d, %Y")
    end

    def credit_creation_date
      [(Time.now.utc.to_date + 1.month).beginning_of_month, Date.new(2023, 7, 1)].max.strftime("%B %-d, %Y")
    end

    def australia_backtax_agreement
      backtax_agreements.where(jurisdiction: BacktaxAgreement::Jurisdictions::AUSTRALIA).first
    end
  end
end
