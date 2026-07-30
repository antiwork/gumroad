# frozen_string_literal: true

class License < ApplicationRecord
  MANAGE_SECURE_ID_SCOPE = "manage_license"

  # Sellers set this by hand from the customer page, so the ceiling only has to be high enough that
  # no real activation count reaches it while still keeping a typo out of the search index.
  MAX_SELLER_SETTABLE_USES = 1_000_000

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

  # Serializes concurrent writers of the column against each other. It does NOT make a caller's
  # idea of the current count safe — the value here overwrites whatever /v2/licenses/verify has
  # incremented in the meantime, which is what the seller asked for when they typed an exact
  # number. Relative changes must go through #adjust_uses! instead.
  def set_uses!(value)
    with_lock { update!(uses: value) }
  end

  # Reads the count inside the lock so a concurrent /v2/licenses/verify increment is preserved
  # rather than overwritten. The ceiling only applies while the count is inside the seller-editable
  # range: verify increments without a ceiling, so a count already above it is real activation and
  # clamping would silently delete some of it.
  def adjust_uses!(delta)
    with_lock do
      current = uses.to_i
      target = current + delta
      target = target.clamp(0, MAX_SELLER_SETTABLE_USES) if current <= MAX_SELLER_SETTABLE_USES
      update!(uses: [target, 0].max)
    end
  end

  def reset_uses!
    set_uses!(0)
  end

  def rotate!
    self.serial = nil
    generate_serial
    save!
  end

  def increment!(attribute, by = 1, touch: nil)
    super.tap do
      enqueue_purchase_search_index_update(["license_uses"]) if attribute.to_s == "uses"
    end
  end

  private
    def update_purchase_search_index
      fields = []
      fields << "license_serial" if previous_changes.key?("serial")
      fields << "license_uses" if previous_changes.key?("uses")
      enqueue_purchase_search_index_update(fields)
    end

    def enqueue_purchase_search_index_update(fields)
      return if purchase_id.blank? || fields.blank?

      ElasticsearchIndexerWorker.perform_in(2.seconds, "update", {
                                              "record_id" => purchase_id,
                                              "class_name" => "Purchase",
                                              "fields" => fields
                                            })
    end
end
