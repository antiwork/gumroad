# frozen_string_literal: true

Braintree::Configuration.environment = Rails.env.production? ? :production : :sandbox
Braintree::Configuration.merchant_id = GlobalConfig.get("BRAINTREE_MERCHANT_ID")
Braintree::Configuration.public_key = GlobalConfig.get("BRAINTREE_PUBLIC_KEY")
Braintree::Configuration.private_key = GlobalConfig.get("BRAINTREE_API_PRIVATE_KEY")
Braintree::Configuration.http_open_timeout = 20
Braintree::Configuration.http_read_timeout = 20

BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS = GlobalConfig.get("BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS")
