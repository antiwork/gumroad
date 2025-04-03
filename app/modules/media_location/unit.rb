# frozen_string_literal: true

module MediaLocation::Unit
  PAGE_NUMBER = "page_number"
  SECONDS = "seconds"
  PERCENTAGE = "percentage"

  def self.all
    [
      PAGE_NUMBER,
      SECONDS,
      PERCENTAGE
    ]
  end
end
