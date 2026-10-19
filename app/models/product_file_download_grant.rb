# frozen_string_literal: true

# Per-buyer download permission for one file. Consulted by UrlRedirect#is_file_downloadable?,
# which otherwise reads only the seller's per-file flag.
class ProductFileDownloadGrant < ApplicationRecord
  belongs_to :url_redirect
  belongs_to :product_file

  validates :product_file_id, uniqueness: { scope: :url_redirect_id }
end
