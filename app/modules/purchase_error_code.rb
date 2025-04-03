# frozen_string_literal: true

module PurchaseErrorCode
  INVALID_NUMBER =  "invalid_number"
  HIGH_RISK_COUNTRY = "high_risk_country"
  PRICE_TOO_HIGH = "price_too_high"
  BLOCKED_BROWSER_GUID = "blocked_browser_guid"
  BLOCKED_EMAIL_DOMAIN = "blocked_email_domain"
  BLOCKED_IP_ADDRESS = "blocked_ip_address"
  BLOCKED_CHARGE_PROCESSOR_FINGERPRINT = "blocked_charge_processor_fingerprint"
  BLOCKED_CUSTOMER_EMAIL_ADDRESS = "blocked_customer_email_address"
  BLOCKED_CUSTOMER_CHARGE_PROCESSOR_FINGERPRINT = "blocked_customer_charge_processor_fingerprint"
  TEMPORARILY_BLOCKED_EMAIL_ADDRESS = "email_temporarily_blocked"
  SUSPENDED_BUYER = "suspended_buyer"
  STRIPE_UNAVAILABLE = "stripe_unavailable"
  PAYPAL_UNAVAILABLE = "paypal_unavailable"
  PROCESSING_ERROR = "processing_error"
  SAFE_MODE_HIGH_PROXY_SCORE = "safe_mode_high_ip_proxy_score"
  SAFE_MODE_RESTRICTED_ORGANIZATION = "safe_mode_restricted_organization"
  HIGH_PROXY_SCORE_AND_ADDITIONAL_CONTRIBUTION = "high_proxy_score_can_only_buy_once"
  BUYER_CHARGED_BACK = "buyer_has_charged_back"
  CANADIAN_PAYPAL_SCAMMER = "canadian_paypal_scammer"
  PRICE_CENTS_TOO_LOW = "price_cents_too_low"
  CONTRIBUTION_TOO_LOW = "contribution_too_low"
  ADDITIONAL_CONTRIBUTION_TOO_LOW = "additional_contribution_too_low" # deprecated
  BAD_PLUGINS = "bad_plugins"
  FORCED_APPEARANCE_AS_SUCCESSFUL_CHARGE = "forced_appearance_as_successful_charge"
  FORCED_APPERANCE_AS_FAILED_CHARGE = "forced_appearance_as_failed_charge"
  CREDIT_CARD_NOT_PROVIDED = "credit_card_not_provided"
  OFFER_CODE_INACTIVE = "offer_code_inactive"
  OFFER_CODE_INSUFFICIENT_QUANTITY = "offer_code_insufficient_quantity"
  OFFER_CODE_INVALID = "offer_code_invalid"
  OFFER_CODE_SOLD_OUT = "offer_code_sold_out"
  EXCEEDING_OFFER_CODE_QUANTITY = "exceeding_offer_code_quantity"
  SUBSCRIPTION_INACTIVE = "subscription_inactive"
  PERCEIVED_PRICE_CENTS_NOT_MATCHING = "perceived_price_cents_not_matching"
  PRODUCT_SOLD_OUT = "product_sold_out"
  INVALID_QUANTITY = "invalid_quantity"
  EXCEEDING_PRODUCT_QUANTITY = "exceeding_product_quantity"
  VARIANT_SOLD_OUT = "variant_sold_out"
  EXCEEDING_VARIANT_QUANTITY = "exceeding_variant_quantity"
  MISSING_VARIANTS = "missing_variants"
  NOT_FOR_SALE = "not_for_sale"
  TEMPORARILY_BLOCKED_PRODUCT = "product_temporarily_blocked"
  TAX_VALIDATION_FAILED = "tax_location_validation_failed"
  ONLY_FOR_RENT = "only_for_rent"
  NOT_FOR_RENT = "not_for_rent"
  NO_SHIPPING_COUNTRY_CONFIGURED = "cant_ship_to_country"
  BLOCKED_SHIPPING_COUNTRY = "compliance_blocked_country"
  PPP_CARD_COUNTRY_NOT_MATCHING = "ppp_card_country_not_matching"
  PAYPAL_MERCHANT_ACCOUNT_RESTRICTED = "paypal_merchant_account_restricted"
  PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT = "paypal_payer_cancelled_billing_agreement"
  PAYPAL_PAYER_ACCOUNT_DECLINED_PAYMENT = "paypal_payer_account_declined_payment"
  STRIPE_INSUFFICIENT_FUNDS = "card_declined_insufficient_funds"
  NET_NEGATIVE_SELLER_REVENUE = "net_negative_seller_revenue"
  CARD_DECLINED_FRAUDULENT = "card_declined_fraudulent"
  BRAZILIAN_MERCHANT_ACCOUNT_WITH_AFFILIATE = "brazilian_merchant_account_with_affiliate"

  PAYPAL_ERROR_CODES = {
    "2000" => "Do Not Honor",
    "2001" => "Insufficient Funds",
    "2002" => "Limit Exceeded",
    "2003" => "Cardholder's Activity Limit Exceeded",
    "2004" => "Expired Card",
    "2005" => "Invalid Credit Card Number",
    "2006" => "Invalid Expiration Date",
    "2007" => "No Account",
    "2008" => "Card Account Length Error",
    "2009" => "No Such Issuer",
    "2010" => "Card Issuer Declined CVV",
    "2011" => "Voice Authorization Required",
    "2012" => "Processor Declined - Possible Lost Card",
    "2013" => "Processor Declined - Possible Stolen Card",
    "2014" => "Processor Declined - Fraud Suspected",
    "2015" => "Transaction Not Allowed",
    "2016" => "Duplicate Transaction",
    "2017" => "Cardholder Stopped Billing",
    "2018" => "Cardholder Stopped All Billing",
    "2019" => "Invalid Transaction",
    "2020" => "Violation",
    "2021" => "Security Violation",
    "2022" => "Declined - Updated Cardholder Available",
    "2023" => "Processor Does Not Support This Feature",
    "2024" => "Card Type Not Enabled",
    "2025" => "Set Up Error - Merchant",
    "2026" => "Invalid Merchant ID",
    "2027" => "Set Up Error - Amount",
    "2028" => "Set Up Error - Hierarchy",
    "2029" => "Set Up Error - Card",
    "2030" => "Set Up Error - Terminal",
    "2031" => "Encryption Error",
    "2032" => "Surcharge Not Permitted",
    "2033" => "Inconsistent Data",
    "2034" => "No Action Taken",
    "2035" => "Partial Approval For Amount In Group III Version",
    "2036" => "Authorization could not be found",
    "2037" => "Already Reversed",
    "2038" => "Processor Declined",
    "2039" => "Invalid Authorization Code",
    "2040" => "Invalid Store",
    "2041" => "Declined - Call For Approval",
    "2042" => "Invalid Client ID",
    "2043" => "Error - Do Not Retry, Call Issuer",
    "2044" => "Declined - Call Issuer",
    "2045" => "Invalid Merchant Number",
    "2046" => "Declined",
    "2047" => "Call Issuer. Pick Up Card",
    "2048" => "Invalid Amount",
    "2049" => "Invalid SKU Number",
    "2050" => "Invalid Credit Plan",
    "2051" => "Credit Card Number does not match method of payment",
    "2053" => "Card reported as lost or stolen",
    "2054" => "Reversal amount does not match authorization amount",
    "2055" => "Invalid Transaction Division Number",
    "2056" => "Transaction amount exceeds the transaction division limit",
    "2057" => "Issuer or Cardholder has put a restriction on the card",
    "2058" => "Merchant not Mastercard SecureCode enabled",
    "2059" => "Address Verification Failed",
    "2060" => "Address Verification and Card Security Code Failed",
    "2061" => "Invalid Transaction Data",
    "2062" => "Invalid Tax Amount",
    "2063" => "PayPal Business Account preference resulted in the transaction failing",
    "2064" => "Invalid Currency Code",
    "2065" => "Refund Time Limit Exceeded",
    "2066" => "PayPal Business Account Restricted",
    "2067" => "Authorization Expired",
    "2068" => "PayPal Business Account Locked or Closed",
    "2069" => "PayPal Blocking Duplicate Order IDs",
    "2070" => "PayPal Buyer Revoked Pre-Approved Payment Authorization",
    "2071" => "PayPal Payee Account Invalid Or Does Not Have a Confirmed Email",
    "2072" => "PayPal Payee Email Incorrectly Formatted",
    "2073" => "PayPal Validation Error",
    "2074" => "Funding Instrument In The PayPal Account Was Declined By The Processor Or Bank, Or It Can't Be Used For This Payment",
    "2075" => "Payer Account Is Locked Or Closed",
    "2076" => "Payer Cannot Pay For This Transaction With PayPal",
    "2077" => "Transaction Refused Due To PayPal Risk Model",
    "2079" => "PayPal Merchant Account Configuration Error",
    "2081" => "PayPal pending payments are not supported",
    "2082" => "PayPal Domestic Transaction Required",
    "2083" => "PayPal Phone Number Required",
    "2084" => "PayPal Tax Info Required",
    "2085" => "PayPal Payee Blocked Transaction",
    "2086" => "PayPal Transaction Limit Exceeded",
    "2087" => "PayPal reference transactions not enabled for your account",
    "2088" => "Currency not enabled for your PayPal seller account",
    "2089" => "PayPal payee email permission denied for this request",
    "2090" => "PayPal account not configured to refund more than settled amount",
    "2091" => "Currency of this transaction must match currency of your PayPal account",
    "2092" => "No Data Found - Try Another Verification Method",
    "2093" => "PayPal payment method is invalid",
    "2094" => "PayPal payment has already been completed",
    "2095" => "PayPal refund is not allowed after partial refund",
    "2096" => "PayPal buyer account can't be the same as the seller account",
    "2097" => "PayPal authorization amount limit exceeded",
    "2098" => "PayPal authorization count limit exceeded",
    "2099" => "Cardholder Authentication Required",
    "2100" => "PayPal channel initiated billing not enabled for your account",
    "2101-2999" => "Processor Declined", # No need to match these just placeholder.
    "3000" => "Processor Network Unavailable - Try Again",
    PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT => "Customer has cancelled the billing agreement on PayPal.",
    PAYPAL_PAYER_ACCOUNT_DECLINED_PAYMENT => "Customer PayPal account has declined the payment.",
    "paypal_capture_failure" => "The transaction was declined for an unknown reason.",
  }.freeze

  STRIPE_ERROR_CODES = {
    "authentication_required" => "The card was declined as the transaction requires authentication.",
    "approve_with_id" => "The payment cannot be authorized.",
    "call_issuer" => "The card has been declined for an unknown reason.",
    "card_not_supported" => "The card does not support this type of purchase.",
    "card_velocity_exceeded" => "The customer has exceeded the balance or credit limit available on their card.",
    "currency_not_supported" => "The card does not support the specified currency.",
    "do_not_honor" => "The card has been declined for an unknown reason.",
    "do_not_try_again" => "The card has been declined for an unknown reason.",
    "duplicate_transaction" => "A transaction with identical amount and credit card information was submitted very recently.",
    "expired_card" => "The card has expired.",
    "fraudulent" => "The payment has been declined as Stripe suspects it is fraudulent.",
    "generic_decline" => "The card has been declined for an unknown reason.",
    "incorrect_number" => "The card number is incorrect.",
    "incorrect_cvc" => "The CVC number is incorrect.",
    "incorrect_pin" => "The PIN entered is incorrect. This decline code only applies to payments made with a card reader.",
    "incorrect_zip" => "The ZIP/postal code is incorrect.",
    "insufficient_funds" => "The card has insufficient funds to complete the purchase.",
    "invalid_amount" => "The payment amount is invalid, or exceeds the amount that is allowed.",
    "invalid_cvc" => "The CVC number is incorrect.",
    "invalid_expiry_month" => "The expiration month is invalid.",
    "invalid_expiry_year" => "The expiration year is invalid.",
    "invalid_number" => "The card number is incorrect.",
    "invalid_pin" => "The PIN entered is incorrect. This decline code only applies to payments made with a card reader.",
    "issuer_not_available" => "The card issuer could not be reached, so the payment could not be authorized.",
    "lost_card" => "The payment has been declined because the card is reported lost.",
    "merchant_blacklist" => "The payment has been declined because it matches a value on the Stripe user’s block list.",
    "new_account_information_available" => "The card, or account the card is connected to, is invalid.",
    "no_action_taken" => "The card has been declined for an unknown reason.",
    "not_permitted" => "The payment is not permitted.",
    "offline_pin_required" => "The card has been declined as it requires a PIN.",
    "online_or_offline_pin_required" => "The card has been declined as it requires a PIN.",
    "pickup_card" => "The card cannot be used to make this payment (it is possible it has been reported lost or stolen).",
    "pin_try_exceeded" => "The allowable number of PIN tries has been exceeded.",
    "processing_error" => "An error occurred while processing the card.",
    "reenter_transaction" => "The payment could not be processed by the issuer for an unknown reason.",
    "restricted_card" => "The card cannot be used to make this payment (it is possible it has been reported lost or stolen).",
    "revocation_of_all_authorizations" => "The card has been declined for an unknown reason.",
    "revocation_of_authorization" => "The card has been declined for an unknown reason.",
    "security_violation" => "The card has been declined for an unknown reason.",
    "service_not_allowed" => "The card has been declined for an unknown reason.",
    "stolen_card" => "The payment has been declined because the card is reported stolen.",
    "stop_payment_order" => "The card has been declined for an unknown reason.",
    "testmode_decline" => "A Stripe test card number was used.",
    "transaction_not_allowed" => "The card has been declined for an unknown reason.",
    "try_again_later" => "The card has been declined for an unknown reason.",
    "withdrawal_count_limit_exceeded" => "The customer has exceeded the balance or credit limit available on their card."
  }.freeze

  FRAUD_RELATED_ERROR_CODES = [CARD_DECLINED_FRAUDULENT, "card_declined_lost_card", "card_declined_pickup_card", "card_declined_stolen_card"].freeze

  PAYMENT_ERROR_CODES = PAYPAL_ERROR_CODES.keys
                                          .concat(STRIPE_ERROR_CODES.keys)
                                          .concat([
                                                    STRIPE_UNAVAILABLE,
                                                    PAYPAL_UNAVAILABLE,
                                                    PROCESSING_ERROR,
                                                    CREDIT_CARD_NOT_PROVIDED,
                                                  ])

  UNBLOCK_BUYER_ERROR_CODES = FRAUD_RELATED_ERROR_CODES + [TEMPORARILY_BLOCKED_EMAIL_ADDRESS]

  def self.customer_error_message(error = nil)
    error || "Your card was declined. Please try a different card or contact your bank."
  end

  def self.is_temporary_network_error?(error_code)
    error_code == STRIPE_UNAVAILABLE || error_code == PAYPAL_UNAVAILABLE || error_code == PROCESSING_ERROR
  end

  def self.is_error_retryable?(error_code)
    error_code == STRIPE_INSUFFICIENT_FUNDS
  end
end
