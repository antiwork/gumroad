# frozen_string_literal: true

class FactoryBotLinting
  def process
    Rails.application.load_seed

    VCR.turn_on!
    cassette_options = { match_requests_on: [:method, uri_matcher] }

    FactoryBot.factories.each do |factory|
      VCR.use_cassette("factory_linting/factories/#{factory.name}/all_requests", cassette_options) do
        FactoryBot.lint [factory]
      end
    end
  end

  private
    def match_ignoring_trailing_id(uri_1, uri_2, uri_regexp)
      uri_1_id = uri_1.match(uri_regexp) { $1 }
      r1_without_id = uri_1.gsub(uri_1_id, "")

      uri_2_id = uri_2.match(uri_regexp) { $1 }
      r2_without_id = uri_2_id && uri_2.gsub(uri_2_id, "")

      r2_without_id && (r1_without_id == r2_without_id)
    end

    def uri_matcher
      lambda do |request_1, request_2|
        uri_1, uri_2 = request_1.uri, request_2.uri

        pwnedpasswords_range_regexp = %r(https://api.pwnedpasswords.com/range/(.+)/?\z)
        stripe_collection_regexp = %r(https://api.stripe.com/v1/accounts|tokens|customers|payment_methods/?\z)
        stripe_member_regexp = %r(https://api.stripe.com/v1/accounts|tokens|payment_methods/(.+)/?\z)

        case uri_1
        when pwnedpasswords_range_regexp
          match_ignoring_trailing_id(uri_1, uri_2, pwnedpasswords_range_regexp)
        when stripe_collection_regexp
          uri_1 == uri_2
        when stripe_member_regexp
          match_ignoring_trailing_id(uri_1, uri_2, stripe_member_regexp)
        else
          uri_1 == uri_2
        end
      end
    end
end
