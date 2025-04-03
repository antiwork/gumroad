# frozen_string_literal: true

class UtmLinkVisit < ApplicationRecord
  has_paper_trail

  belongs_to :utm_link
  belongs_to :user, optional: true
  has_many :utm_link_driven_sales, dependent: :destroy
  has_many :purchases, through: :utm_link_driven_sales

  validates :ip_address, presence: true
  validates :browser_guid, presence: true
end
