# frozen_string_literal: true

class License < ApplicationRecord
  MANAGE_SECURE_ID_SCOPE = "manage_license"

  has_paper_trail only: %i[disabled_at serial]

  include FlagShihTzu
  include ExternalId
  include SecureExternalId

  validates_numericality_of :uses, greater_than_or_equal_to: 0
  validates_presence_of :serial

  belongs_to :link, optional: true
  belongs_to :purchase, optional: true
  belongs_to :imported_customer, optional: true

  before_validation :generate_serial, on: :create
  after_commit :update_purchase_search_index, on: :update

  has_flags 1 => :DEPRECATED_is_pregenerated,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  def generate_serial
    return if serial.present?

    self.serial = SecureRandom.uuid.upcase.delete("-").scan(/.{8}/).join("-")
  end

  def disabled?
    disabled_at?
  end

  def disable!
    self.disabled_at = Time.current
    save!
  end

  def enable!
    self.disabled_at = nil
    save!
  end

  def reset_uses!
    update!(uses: 0)
  end

  def rotate!
    self.serial = nil
    generate_serial
    save!
  end

  def increment!(attribute, by = 1, touch: nil)
    super.tap do
      if attribute.to_s == "uses"
        enqueue_purchase_search_index_update(["license_uses"])
        update_purchase_audience_member_details
      end
    end
  end

  private
    def update_purchase_search_index
      fields = []
      fields << "license_serial" if previous_changes.key?("serial")
      fields << "license_uses" if previous_changes.key?("uses")
      enqueue_purchase_search_index_update(fields)
      update_purchase_audience_member_details if previous_changes.key?("uses")
    end

    def enqueue_purchase_search_index_update(fields)
      return if purchase_id.blank? || fields.blank?

      ElasticsearchIndexerWorker.perform_in(2.seconds, "update", {
                                              "record_id" => purchase_id,
                                              "class_name" => "Purchase",
                                              "fields" => fields
                                            })
    end

    # Kept off the request on purpose. Writing the buyer's AudienceMember document rewrites a
    # JSON column holding all of that buyer's purchases, which locks the row; doing it inline
    # made concurrent license verifications for the same buyer queue up on that lock and time
    # out with a 500. The audience data is only read later by email-audience filters, so a
    # couple of seconds of delay is fine, and the job deduplicates per purchase while queued
    # so a burst of verifications results in one rewrite rather than one per call.
    def update_purchase_audience_member_details
      return if purchase_id.blank?

      UpdatePurchaseAudienceMemberDetailsJob.perform_in(2.seconds, purchase_id)
    end
end
