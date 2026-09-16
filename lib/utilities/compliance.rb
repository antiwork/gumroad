# frozen_string_literal: true

module Compliance
  DEFAULT_TOS_VIOLATION_REASON = "intellectual property infringement"
  EXPLICIT_NSFW_TOS_VIOLATION_REASON = "Sexually explicit or fetish-related"
  TOS_VIOLATION_REASONS = {
    "A consulting service" => "consulting services",
    "Adult (18+) content" => "adult content",
    "Cell phone and electronics" => "cell phone and electronics",
    "Credit repair" => "credit repair",
    "Financial instruments & currency" => "financial instruments, advice or currency",
    "General non-compliance" => "products that breach our ToS",
    "IT support" => "computer and internet support services",
    "Intellectual Property" => DEFAULT_TOS_VIOLATION_REASON,
    "Online gambling" => "online gambling",
    "Pharmaceutical & Health products" => "pharmaceutical and health products",
    "Service billing" => "payment for services rendered",
    "Web hosting" => "web hosting"
  }.freeze

  VAT_EXEMPT_REGIONS = ["Canarias", "Canary Islands"].freeze
  # Spanish postal-code prefixes outside the EU VAT area: Las Palmas (35), Santa Cruz de
  # Tenerife (38), Ceuta (51), Melilla (52).
  ES_VAT_EXEMPT_POSTAL_PREFIXES = %w[35 38 51 52].freeze

  def self.es_postal_code_vat_exempt?(postal_code)
    digits = postal_code.to_s.strip
    digits.match?(/\A\d{5}\z/) && ES_VAT_EXEMPT_POSTAL_PREFIXES.include?(digits[0, 2])
  end
end
