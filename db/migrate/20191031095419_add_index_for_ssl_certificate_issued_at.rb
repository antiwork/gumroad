# frozen_string_literal: true

class AddIndexForSslCertificateIssuedAt < ActiveRecord::Migration
  def up
    add_index :custom_domains, :ssl_certificate_issued_at
  end

  def down
    remove_index :custom_domains, :ssl_certificate_issued_at
  end
end
