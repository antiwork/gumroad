# frozen_string_literal: true

class CreatorContactingCustomersEmailInfo < EmailInfo
  EMAIL_INFO_TYPE = "creator_contacting_customers"

  validates_presence_of :installment
end
