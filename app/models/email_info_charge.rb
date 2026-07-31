# frozen_string_literal: true

class EmailInfoCharge < ApplicationRecord
  belongs_to :email_info
  belongs_to :charge

  validates :email_info, presence: true, uniqueness: true
  # Deliberately not unique on charge: each send gets its own EmailInfo, so a
  # resent receipt adds a row here rather than overwriting the original send's
  # delivery evidence (gumroad-private#1635). Readers take the newest row.
  validates :charge, presence: true
end
