# frozen_string_literal: true

# The one place a report is opened, for both the seller's dashboard and the admin API.
class PiracyReports::CreateService
  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(seller:, product:, url:, source:, actor:, ticket_url: nil)
    @seller = seller
    @product = product
    @url = url.to_s.strip
    @source = source
    @actor = actor
    @ticket_url = ticket_url.presence
  end

  # The seller row lock makes the monthly count and the insert one step, so parallel requests
  # cannot all read a count below the limit.
  def call
    seller.with_lock do
      errors = guard_errors
      next Result.new(errors:) if errors.any?

      report = PiracyReport.new(seller:, product:, url:, source:, ticket_url:, creation_actor: actor)
      report.save!
      Result.new(report:, errors: [])
    end
  rescue ActiveRecord::RecordNotUnique
    Result.new(errors: ["This page has already been reported for this product"])
  rescue ActiveRecord::RecordInvalid => e
    Result.new(errors: e.record.errors.full_messages)
  end

  private
    attr_reader :seller, :product, :url, :source, :actor, :ticket_url

    def guard_errors
      errors = PiracyReports::Eligibility.new(seller:, product:).errors
      errors.concat(url_errors)
      if PiracyReport.created_this_month_count(seller) >= PiracyReport::MONTHLY_LIMIT
        errors << "The monthly limit of #{PiracyReport::MONTHLY_LIMIT} reports has been reached"
      end
      errors
    end

    def url_errors
      uri = PiracyReport.parse_http_url(url)
      return ["The URL must start with http:// or https://"] if uri.nil?
      return [PiracyReport::HOSTED_ON_GUMROAD_ERROR] if PiracyReport.gumroad_hosted?(uri.host)
      return ["This page has already been reported for this product"] if already_reported?

      []
    end

    # Any state counts, declined included: a declined page is not re-filed automatically.
    def already_reported?
      digest = Digest::SHA256.hexdigest(PiracyReport.normalize_url(url))
      PiracyReport.exists?(product_id: product.id, normalized_url_digest: digest)
    end
end
