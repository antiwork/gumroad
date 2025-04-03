# frozen_string_literal: true

class AddSslCertificateIssuedAtToCustomDomain < ActiveRecord::Migration
  def change
    add_column :custom_domains, :ssl_certificate_issued_at, :datetime
  end
end
