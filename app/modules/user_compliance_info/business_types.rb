# frozen_string_literal: true

module UserComplianceInfo::BusinessTypes
  LLC = "llc"
  PARTNERSHIP = "partnership"
  NON_PROFIT = "profit"
  REGISTERED_CHARITY = "registered_charity"
  SOLE_PROPRIETORSHIP = "sole_proprietorship"
  CORPORATION = "corporation"

  def self.all
    [
      LLC,
      PARTNERSHIP,
      NON_PROFIT,
      SOLE_PROPRIETORSHIP,
      CORPORATION
    ]
  end

  # https://payable.com/taxes/part-2-how-to-set-up-a-full-form-import-1099-misc-1099-k
  # ‘INDIVIDUAL’, ‘CORPORATION’, ‘LLC_SINGLE’, LLC_C_CORP’, ‘LLC_S_CORP’, ‘LLC_PARTNER’, ‘C_CORP’, ‘S_CORP’, ‘PARTNERSHIP’, ’NON_PROFIT’.
  def payable_type_map
    { LLC => "LLC_PARTNER",
      PARTNERSHIP => "PARTNERSHIP",
      NON_PROFIT => "NON_PROFIT",
      SOLE_PROPRIETORSHIP => "INDIVIDUAL",
      CORPORATION => "CORPORATION"
    }
  end

  BUSINESS_TYPES_UAE = {
    "llc" => "LLC",
    "sole_establishment" => "Sole Establishment",
    "free_zone_llc" => "Free Zone LLC",
    "free_zone_establishment" => "Free Zone Establishment"
  }.freeze

  BUSINESS_TYPES_INDIA = {
    "sole_proprietorship" => "Sole Proprietorship",
    "partnership" => "Partnership",
    "llp" => "Limited Liability Partnership (LLP)",
    "pvt_ltd" => "Private Limited Company (Pvt Ltd)",
    "pub_ltd" => "Public Limited Company (Ltd)",
    "opc" => "One-Person Company (OPC)",
    "jvc" => "Joint-Venture Company (JVC)",
    "ngo" => "Non-Government Organization (NGO)"
  }.freeze

  BUSINESS_TYPES_CANADA = {
    "private_corporation" => "Private Corporation",
    "private_partnership" => "Private Partnership",
    "sole_proprietorship" => "Sole Proprietorship",
    "public_corporation" => "Public Corporation",
    "non_profit" => "Non Profit",
    "registered_charity" => "Registered Charity"
  }.freeze
end
