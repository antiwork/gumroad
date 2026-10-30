# frozen_string_literal: true

# Rewrites purchases.json_data rows that MySQL cut to 255 characters while the column was a varchar(255).
# Each target names the exact cut value still stored, the PaperTrail version whose write was cut, and the
# full value a person read from that version's object_changes. The service only checks and writes those
# values: anything that does not match exactly is skipped, never guessed or merged.
class Onetime::RepairTruncatedPurchaseJsonData
  TRUNCATED_LENGTH = 255

  Target = Data.define(:purchase_id, :version_id, :stored_json_data, :approved_json_data)

  def initialize(targets:, dry_run: true)
    @targets = targets.map { Target.new(**_1.to_h.symbolize_keys) }
    @dry_run = dry_run
  end

  def process
    ApplicationRecord.connected_to(role: :writing) do
      raise "purchases.json_data must be widened before repairing" unless column_limit > TRUNCATED_LENGTH

      @targets.map { repair(_1) }
    end
  end

  private
    def repair(target)
      Purchase.transaction(requires_new: true) do
        rows = Purchase.connection.select_rows(Purchase.unscoped.where(id: target.purchase_id).lock.select(:json_data).to_sql)
        stored = rows.dig(0, 0)
        status = if rows.empty?
          :purchase_not_found
        elsif stored == target.approved_json_data && approved_hash?(target)
          :already_repaired
        else
          skip_reason(target, stored) || (@dry_run ? :dry_run : write(target))
        end
        result = { purchase_id: target.purchase_id, version_id: target.version_id, status: }
        Rails.logger.info("[RepairTruncatedPurchaseJsonData] #{result.to_json}")
        result
      end
    end

    def skip_reason(target, stored)
      return :row_changed unless stored == target.stored_json_data
      return :not_truncated unless stored.is_a?(String) && stored.length == TRUNCATED_LENGTH && !parses?(stored)
      return :approved_value_not_a_full_hash unless approved_hash?(target) && target.approved_json_data.length > TRUNCATED_LENGTH
      return :approved_value_too_long if target.approved_json_data.length > column_limit
      return :approved_value_does_not_extend_stored unless target.approved_json_data.start_with?(stored)

      version = PaperTrail::Version.find_by(id: target.version_id, item_type: "Purchase", item_id: target.purchase_id)
      return :version_not_found if version.nil?
      return :version_does_not_record_approved_value unless recorded_json_data(version) == target.approved_json_data
      :later_version_may_change_json_data if later_versions_may_change_json_data?(version)
    end

    # update_all skips PaperTrail (its callbacks would parse the cut value) and JsonData's length guard.
    # The audit is written in the same transaction, so its failure undoes the repair.
    def write(target)
      Purchase.unscoped.where(id: target.purchase_id).update_all(["json_data = ?", target.approved_json_data])
      PaperTrail::Version.create!(
        item_type: "Purchase", item_id: target.purchase_id, event: "update", whodunnit: self.class.name,
        object_changes: PaperTrail.serializer.dump("json_data" => [target.stored_json_data, target.approved_json_data])
      )
      :repaired
    end

    # A later version with missing or unreadable object_changes may have changed json_data too.
    def later_versions_may_change_json_data?(version)
      PaperTrail::Version.with_item_keys("Purchase", version.item_id).subsequent(version).pluck(:object_changes).any? do |object_changes|
        changes = load_object_changes(object_changes)
        changes.nil? || changes.key?("json_data")
      end
    end

    def recorded_json_data(version)
      change = load_object_changes(version.object_changes)&.dig("json_data")
      change.last if change.is_a?(Array) && change.length == 2
    end

    def load_object_changes(object_changes)
      changes = PaperTrail.serializer.load(object_changes) if object_changes
      changes if changes.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def approved_hash?(target)
      JSON.parse(target.approved_json_data).is_a?(Hash)
    rescue JSON::ParserError, TypeError
      false
    end

    def parses?(value)
      JSON.parse(value)
      true
    rescue JSON::ParserError
      false
    end

    def column_limit
      @column_limit ||= json_data_column_limit
    end

    def json_data_column_limit
      Purchase.connection.columns(:purchases).find { _1.name == "json_data" }.limit
    end
end
