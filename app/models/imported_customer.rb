# frozen_string_literal: true

class ImportedCustomer < ApplicationRecord
  include ExternalId
  include ActionView::Helpers::DateHelper
  include Deletable

  belongs_to :link, optional: true
  belongs_to :importing_user, class_name: "User", optional: true
  has_one :url_redirect
  has_one :license

  after_create :create_or_get_license

  validates_presence_of :email

  scope :by_ids, ->(ids) { where("id IN (?)", ids) }

  def as_json(options = {})
    json = super(only: %i[email created_at])
    json.merge!(timestamp: "#{time_ago_in_words(purchase_date)} ago",
                link_name: link.present? ? link.name : nil,
                product_name: link.present? ? link.name : nil,
                price: nil,
                is_imported_customer: true,
                purchase_email: email,
                id: external_id)
    json[:license_key] = license_key if !options[:without_license_key] && license_key
    json[:can_update] = options[:pundit_user] ? Pundit.policy!(options[:pundit_user], self).update? : nil
    json
  end

  def license_key
    create_or_get_license.try(:serial)
  end

  private
    def create_or_get_license
      return nil unless link.try(:is_licensed?)
      return license if license

      license = create_license
      license.link = link
      license.save!
      license
    end
end
