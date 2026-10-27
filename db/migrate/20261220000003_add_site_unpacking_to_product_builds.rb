# frozen_string_literal: true

# The player serves a build from its unpacked site/ prefix, so the build row records whether the
# zip was unpacked, how much came out of it, and why it was rejected when it was not.
class AddSiteUnpackingToProductBuilds < ActiveRecord::Migration[8.1]
  def change
    change_table :product_builds, bulk: true do |t|
      t.datetime :site_unpacked_at
      t.integer :site_file_count
      t.bigint :site_byte_size
      t.text :site_unpack_error
    end
  end
end
