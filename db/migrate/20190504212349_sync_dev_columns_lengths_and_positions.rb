# frozen_string_literal: true

class SyncDevColumnsLengthsAndPositions < ActiveRecord::Migration
  def up
    VARCHARS_CHANGES_FROM_191_TO_255.each do |table_name, columns_names|
      columns_names.each do |column_name|
        change_column(table_name, column_name, :string, limit: 255)
      end
    end

    TEXTS_CHANGES_FROM_65535_TO_16777215.each do |table_name, columns_names|
      columns_names.each do |column_name|
        change_column(table_name, column_name, :text, limit: 16777215)
      end
    end

    change_column :events, :referrer, :string, limit: 255
    change_column :gifts, :gift_note, :text, limit: 4294967295
    change_column :installments, :message, :text, limit: 4294967295
    change_column :installments, :url, :text, limit: 4294967295
    change_column :product_files, :json_data, :text, limit: 4294967295

    change_column :affiliate_credits, :created_at, :datetime, after: :seller_id
    change_column :affiliate_credits, :updated_at, :datetime, after: :created_at
    change_column :credits, :balance_id, :integer, after: :amount_cents
    change_column :events, :friend_actions, :text, after: :is_modal
    change_column :links, :variants, :text, limit: 16777215, after: :custom_filetype
    change_column :purchases, :ip_address, :string, limit: 255, after: :session_id
    change_column :purchases, :is_mobile, :boolean, after: :ip_address
    change_column :purchases, :variants, :text, after: :stripe_status
    change_column :url_redirects, :flags, :integer, after: :customized_file_url
    change_column :users, :profile_picture_url, :string, limit: 255, after: :credit_card_id
    change_column :users, :country, :string, limit: 255, after: :soundcloud_token
    change_column :users, :state, :string, limit: 255, after: :country
    change_column :users, :city, :string, limit: 255, after: :state
    change_column :users, :zip_code, :string, limit: 255, after: :city
    change_column :users, :street_address, :string, limit: 255, after: :zip_code
  end

  def down
    VARCHARS_CHANGES_FROM_191_TO_255.each do |table_name, columns_names|
      columns_names.each do |column_name|
        change_column(table_name, column_name, :string, limit: 191)
      end
    end

    TEXTS_CHANGES_FROM_65535_TO_16777215.each do |table_name, columns_names|
      columns_names.each do |column_name|
        change_column(table_name, column_name, :text, limit: 65535)
      end
    end

    change_column :events, :referrer, :string, limit: 1024
    change_column :gifts, :gift_note, :text, limit: 65535
    change_column :installments, :message, :text, limit: 65535
    change_column :installments, :url, :text, limit: 65535
    change_column :product_files, :json_data, :text, limit: 65535

    change_column :affiliate_credits, :created_at, :datetime, after: :seller_id
    change_column :affiliate_credits, :updated_at, :datetime, after: :created_at
    change_column :credits, :balance_id, :integer, after: :updated_at
    change_column :events, :friend_actions, :text, after: :browser_guid
    change_column :links, :variants, :text, limit: 65535, after: :territory_restriction
    change_column :purchases, :ip_address, :string, limit: 191, after: :session_id
    change_column :purchases, :is_mobile, :boolean, after: :ip_address
    change_column :purchases, :variants, :text, after: :subunsub
    change_column :url_redirects, :flags, :integer, after: :subscription_id
    change_column :users, :profile_picture_url, :string, limit: 191, after: :soundcloud_token
    change_column :users, :country, :string, limit: 191, after: :profile_meta
    change_column :users, :state, :string, limit: 191, after: :country
    change_column :users, :city, :string, limit: 191, after: :state
    change_column :users, :zip_code, :string, limit: 191, after: :city
    change_column :users, :street_address, :string, limit: 191, after: :zip_code
  end

  VARCHARS_CHANGES_FROM_191_TO_255 = {
    asset_previews: [
      :attachment_content_type,
      :guid,
    ],
    balance_transactions: [
      :issued_amount_currency,
      :holding_amount_currency,
    ],
    balances: [
      :currency,
      :holding_currency,
      :state,
    ],
    bank_accounts: [
      :bank_number,
      :state,
      :account_number_last_four,
      :account_holder_full_name,
      :type,
      :branch_code,
      :account_type,
      :stripe_bank_account_id,
      :stripe_fingerprint,
      :stripe_connect_account_id,
    ],
    banks: [
      :routing_number,
      :name,
    ],
    base_variants: [
      :name,
      :type,
      :custom_sku,
    ],
    bins: [
      :card_bin,
      :issuing_bank,
      :card_type,
      :card_level,
      :iso_country_name,
      :iso_country_a2,
      :iso_country_a3,
      :website,
      :phone_number,
      :card_brand,
    ],
    blocked_ips: [
      :ip_address,
    ],
    comments: [
      :commentable_type,
      :author_name,
      :comment_type,
    ],
    consumption_events: [
      :event_type,
      :platform,
    ],
    credit_cards: [
      :card_type,
      :stripe_customer_id,
      :visual,
      :stripe_fingerprint,
      :card_country,
      :stripe_card_id,
      :card_bin,
      :card_data_handling_mode,
      :charge_processor_id,
      :braintree_customer_id,
    ],
    custom_domains: [
      :domain,
      :type
    ],
    delayed_emails: [
      :email_type,
    ],
    disputes: [
      :charge_processor_id,
      :charge_processor_dispute_id,
      :reason,
      :state,
    ],
    dropbox_files: [
      :state,
    ],
    dynamic_product_page_switches: [
      :name
    ],
    event_test_path_assignments: [
      :event_name,
      :active_test_paths,
    ],
    events: [
      :ip_address,
      :event_name,
      :parent_referrer,
      :language,
      :browser,
      :email,
      :card_type,
      :card_visual,
      :purchase_state,
      :billing_zip,
      :view_url,
      :fingerprint,
      :ip_country,
      :browser_fingerprint,
      :browser_plugins,
      :browser_guid,
      :referrer_domain,
      :ip_state,
      :active_test_path_assignments,
    ],
    failed_purchases: [
      :ip_address,
      :stripe_fingerprint,
      :card_type,
      :card_country,
    ],
    followers: [
      :email,
      :source,
    ],
    gifts: [
      :state,
      :giftee_email,
      :gifter_email,
    ],
    import_jobs: [
      :import_file_url,
      :state,
    ],
    imported_customers: [
      :email,
    ],
    installment_rules: [
      :time_period,
    ],
    installments: [
      :name,
      :installment_type,
      :cover_image_url,
    ],
    invites: [
      :receiver_email,
      :invite_state,
    ],
    licenses: [
      :serial,
      :json_data,
    ],
    links: [
      :name,
      :price_currency_type,
      :partner_source,
      :upc_code,
      :isrc_code,
      :preview_file_name,
      :preview_content_type,
      :preview_guid,
      :attachment_file_name,
      :attachment_content_type,
      :attachment_guid,
      :preview_meta,
      :attachment_meta,
      :custom_filetype,
      :filetype,
      :filegroup,
      :common_color,
      :custom_download_text,
      :attachment_meta,
      :external_mapping_id,
    ],
    merchant_accounts: [
      :acquirer_id,
      :acquirer_merchant_id,
      :charge_processor_id,
      :charge_processor_merchant_id,
      :relationship,
      :country,
      :currency,
    ],
    oauth_access_grants: [
      :token,
      :redirect_uri,
      :scopes,
    ],
    oauth_access_tokens: [
      :token,
      :refresh_token,
      :scopes,
    ],
    oauth_applications: [
      :name,
      :uid,
      :secret,
      :redirect_uri,
      :owner_type,
      :icon_file_name,
      :icon_content_type,
      :icon_guid,
      :scopes,
    ],
    offer_codes: [
      :currency_type,
    ],
    payments: [
      :state,
      :txn_id,
      :unique_id,
      :correlation_id,
      :processor,
      :payment_address,
      :stripe_connect_account_id,
      :stripe_transfer_id,
      :stripe_internal_transfer_id,
      :local_currency,
      :currency,
    ],
    preorder_links: [
      :state,
      :url,
      :attachment_guid,
      :custom_filetype,
    ],
    preorders: [
      :state,
    ],
    prices: [
      :currency,
      :recurrence,
    ],
    product_files: [
      :filetype,
      :filegroup,
    ],
    product_files_archives: [
      :product_files_archive_state,
    ],
    purchase_sales_tax_infos: [
      :elected_country_code,
      :card_country_code,
      :ip_country_code,
      :country_code,
      :postal_code,
      :ip_address,
    ],
    purchases: [
      :displayed_price_currency_type,
      :rate_converted_to_usd,
      :street_address,
      :city,
      :state,
      :zip_code,
      :country,
      :full_name,
      :purchaser_type,
      :session_id,
      :stripe_transaction_id,
      :stripe_fingerprint,
      :stripe_card_id,
      :ip_address,
      :subunsub,
      :referrer,
      :stripe_status,
      :card_type,
      :card_visual,
      :purchase_state,
      :card_country,
      :stripe_error_code,
      :browser_guid,
      :error_code,
      :card_bin,
      :ip_country,
      :ip_state,
      :billing_name,
      :billing_zip_code,
      :credit_card_zipcode,
      :json_data,
      :card_data_handling_mode,
      :charge_processor_id,
      :processor_fee_cents_currency,
    ],
    recommended_purchase_infos: [
      :recommendation_type,
    ],
    resource_subscriptions: [
      :resource_name,
      :post_url,
    ],
    shipments: [
      :ship_state,
      :tracking_number,
      :carrier,
    ],
    shipping_destinations: [
      :country_code,
    ],
    subtitle_files: [
      :language,
    ],
    tos_agreements: [
      :ip,
    ],
    transcoded_videos: [
      :original_video_key,
      :transcoded_video_key,
      :transcoder_preset_key,
      :job_id,
      :state,
    ],
    url_redirects: [
      :token,
      :customized_file_url,
    ],
    user_compliance_info: [
      :full_name,
      :street_address,
      :city,
      :state,
      :zip_code,
      :country,
      :telephone_number,
      :vertical,
      :json_data,
      :business_name,
      :business_street_address,
      :business_city,
      :business_state,
      :business_zip_code,
      :business_country,
      :business_type,
      :dba,
      :first_name,
      :last_name,
      :stripe_identity_document_id,
    ],
    user_compliance_info_requests: [
      :field_needed,
      :state,
    ],
    user_underwriting: [
      :from_relationship,
      :to_relationship,
      :underwriting_state,
      :submission_group_id,
    ],
    users: [
      :reset_password_token,
      :current_sign_in_ip,
      :last_sign_in_ip,
      :name,
      :payment_address,
      :reset_hash,
      :password_salt,
      :provider,
      :currency_type,
      :facebook_profile,
      :facebook_gender,
      :facebook_verified,
      :twitter_handle,
      :twitter_verified,
      :twitter_location,
      :soundcloud_username,
      :soundcloud_token,
      :profile_picture_url,
      :profile_file_name,
      :profile_content_type,
      :profile_guid,
      :profile_meta,
      :country,
      :state,
      :city,
      :zip_code,
      :street_address,
      :fanpage,
      :highlight_color,
      :background_color,
      :background_image_url,
      :external_css_url,
      :account_created_ip,
      :twitter_oauth_token,
      :twitter_oauth_secret,
      :locale,
      :admin_notes,
      :google_analytics_id,
      :timezone,
      :user_risk_state,
      :tos_violation_reason,
      :kindle_email,
      :support_email,
      :conversion_tracking_facebook_id,
      :conversion_tracking_image_url,
      :google_analytics_domains,
      :recommendation_type,
      :background_video_url,
    ],
    variant_categories: [
      :title,
    ],
    workflows: [
      :workflow_type,
    ],
    zip_tax_rates: [
      :state,
      :tax_region_code,
      :tax_region_name,
      :zip_code,
      :country,
    ]
  }

  TEXTS_CHANGES_FROM_65535_TO_16777215 = {
    comments: [
      :content,
      :json_data,
    ],
    dropbox_files: [
      :json_data,
    ],
    installments: [
      :url,
      :json_data,
    ],
    links: [
      :url,
      :preview_url,
      :description,
      :territory_restriction,
      :variants,
      :preview_oembed,
      :custom_receipt,
      :webhook_url,
      :custom_fields,
      :json_data,
    ],
    product_files: [
      :json_data,
    ],
    refunds: [
      :json_data,
    ],
    shipping_destinations: [
      :json_data,
    ],
    users: [
      :custom_css,
      :bio,
      :notification_endpoint,
      :admin_notes,
      :json_data,
      :page_layout,
    ]
  }
end
