# frozen_string_literal: true

class AddSslCertificateIssuedAtToCustomDomain < ActiveRecord::Migration[4.2]
  def change
    add_column :custom_domains, :ssl_certificate_issued_at, :datetime
  end
end
