# frozen_string_literal: true

class EmailInfoCharge < ApplicationRecord
  belongs_to :email_info
  belongs_to :charge

  validates :email_info, presence: true, uniqueness: true
  validates :charge, presence: true, uniqueness: true
end
