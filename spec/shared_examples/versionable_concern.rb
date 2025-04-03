# frozen_string_literal: true

require "spec_helper"

# options contains a hash with versionable fields for factory as keys, and each
# field's value is an array of 2 values: before and after. After value is optional.
# Sample spec integration:
#
# it_behaves_like "Versionable concern", :user, {
#   email: %w(user@example.com),
#   payment_address: %w(old-paypal@example.com paypal@example.com)
# }
#
RSpec.shared_examples_for "Versionable concern" do |factory_name, options|
  with_versioning do
    it "returns version infos" do
      fields = options.keys
      object = create(factory_name, options.transform_values { |values| values.first })

      object.update!(
        options.transform_values { |values| values.second }.select { |_f, value| value.present? }
      )
      version_one, version_two = object.versions_for(*fields)

      expect(version_one.class).to eq(Versionable::VersionInfoStruct)
      expect(version_one.created_at).to be_present
      expect(HashWithIndifferentAccess.new(version_one.changes)).to eq(
        HashWithIndifferentAccess.new(options.select { |field, values| values.size == 2 })
      )
      expect(version_two.changes.keys).to eq(fields.map(&:to_s))
    end

    it "ignores versions without changes" do
      fields = options.keys
      object = create(factory_name, options.transform_values { |values| values.first })
      object.versions.update_all(object_changes: nil)
      expect(object.versions_for(*fields)).to eq([])
    end
  end
end
