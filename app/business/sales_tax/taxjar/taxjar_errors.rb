# frozen_string_literal: true

module TaxjarErrors
  CLIENT = [Taxjar::Error::BadRequest, Taxjar::Error::Unauthorized,
            Taxjar::Error::Forbidden, Taxjar::Error::NotFound,
            Taxjar::Error::MethodNotAllowed, Taxjar::Error::NotAcceptable,
            Taxjar::Error::Gone, Taxjar::Error::UnprocessableEntity,
            Taxjar::Error::TooManyRequests].freeze

  SERVER = [Taxjar::Error::InternalServerError, Taxjar::Error::ServiceUnavailable,
            *INTERNET_EXCEPTIONS].freeze
end
