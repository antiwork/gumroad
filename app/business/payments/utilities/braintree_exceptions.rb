# frozen_string_literal: true

module BraintreeExceptions
  UNAVAILABLE = [Braintree::ServiceUnavailableError, Braintree::SSLCertificateError,
                 Braintree::ServerError, Braintree::UnexpectedError, *INTERNET_EXCEPTIONS].freeze
end
