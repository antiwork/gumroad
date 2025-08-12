# frozen_string_literal: true

# app/models/guardian_compliance_info_request.rb
class GuardianComplianceInfoRequest < ApplicationRecord
  include ExternalId
  include JsonData
  include FlagShihTzu

  belongs_to :user
  validates :user, presence: true

  has_flags 1 => :only_needs_field_to_be_partially_provided,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_json_data_accessor :stripe_event_id
  attr_json_data_writer :emails_sent_at
  attr_json_data_accessor :verification_error
  attr_json_data_accessor :guardian_person_id  # Store Stripe person ID

  state_machine :state, initial: :requested do
    before_transition any => :provided, :do => lambda { |request|
      request.provided_at = Time.current
    }

    event :mark_provided do
      transition requested: :provided
    end

    event :mark_verified do
      transition provided: :verified
    end
  end

  scope :requested, -> { where(state: :requested) }
  scope :provided, -> { where(state: :provided) }
  scope :verified, -> { where(state: :verified) }

  def emails_sent_at
    email_sent_at_raw = json_data_for_attr("emails_sent_at", default: [])
    email_sent_at_raw.map { |email_sent_at| email_sent_at.is_a?(String) ? Time.zone.parse(email_sent_at) : email_sent_at }
  end

  def record_email_sent!(email_sent_at = Time.current)
    self.emails_sent_at = emails_sent_at << email_sent_at
    save!
  end

  def self.handle_new_guardian_compliance_info(user_compliance_info)
    GuardianComplianceInfoFields.all_fields.each do |field|
      field_value = user_compliance_info.send(field)
      field_value = field_value.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")) if field_value.is_a?(Strongbox::Lock)
      next if field_value.blank?

      requests = user_compliance_info.user.guardian_compliance_info_requests.requested.where(field_needed: field)
      requests.find_each(&:mark_provided!)
    end
  end
end
