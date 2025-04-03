# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += %i[password cc_number number expiry_date cc_expiry cvc account_number account_number_repeated passphrase
                                                 chargeable tax_id individual_tax_id business_tax_id ssn_first_three ssn_middle_two ssn_last_four]
