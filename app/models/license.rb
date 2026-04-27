# frozen_string_literal: true

class License < ApplicationRecord
  has_paper_trail only: %i[disabled_at serial]

  include FlagShihTzu
  include ExternalId

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
