# frozen_string_literal: true

# A file's download flag is a seller-facing, per-file setting, so it can only be turned off for
# every buyer of that product. One row here lets a single buyer's url redirect download one file
# while the rest keep the in-browser reader.
class CreateProductFileDownloadGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :product_file_download_grants do |t|
      t.bigint :url_redirect_id, null: false
      t.bigint :product_file_id, null: false
      t.timestamps

      t.index [:url_redirect_id, :product_file_id],
              unique: true,
              name: "index_product_file_download_grants_on_redirect_and_file"
    end
  end
end
