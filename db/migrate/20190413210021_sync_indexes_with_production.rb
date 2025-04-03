# frozen_string_literal: true

class SyncIndexesWithProduction < ActiveRecord::Migration
  def up
    # ==========
    # Following indexes exist in dev, not in production
    # ==========

    create_index_unless_exists(:affiliate_credits, :link_id, :index_affiliate_credits_on_link_id)
    create_index_unless_exists(:affiliate_credits, :purchase_id, :index_affiliate_credits_on_purchase_id)
    create_index_unless_exists(:followers, [:followed_id, :email], :index_follows_on_followed_id_and_email)

    # The following 3 have an unusal name in production.
    # MySQL 5.6 does not allow renaming of indexes, so we are recreating the ones in dev rather than touching the ones in production.
    recreate_index(:purchases, :purchase_chargeback_balance_id, before: :index_purchases_on_purchase_chargeback_balance_id, after: :index_purchase_chargeback_balance_id)
    recreate_index(:purchases, :purchase_refund_balance_id, before: :index_purchases_on_purchase_refund_balance_id, after: :index_purchase_refund_balance_id)
    recreate_index(:purchases, :purchase_success_balance_id, before: :index_purchases_on_purchase_success_balance_id, after: :index_purchase_success_balance_id)

    # If a column is varchar(191) and an index is created with that length, AR will NOT declare that length in the schema dump.
    # If a column is varchar(255) and an index is created with a different length, AR will.
    # The problem with these columns is that they either have mismatching lengths on dev & prod, and/or index column lengths.
    # Here we are removing the dev ones and replacing them with the prod version.
    resize_columns_and_recreate_index(:links, :index_links_on_custom_permalink, lengths: { custom_permalink: 191 })
    resize_columns_and_recreate_index(:links, :index_links_on_unique_permalink, lengths: { unique_permalink: 191 })
    resize_columns_and_recreate_index(:offer_codes, :index_offer_codes_on_name_and_link_id, lengths: { name: 191, link_id: nil })
    resize_columns_and_recreate_index(:users, :index_users_on_confirmation_token, lengths: { confirmation_token: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_email, lengths: { email: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_external_id, lengths: { external_id: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_facebook_uid, lengths: { facebook_uid: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_twitter_user_id, lengths: { twitter_user_id: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_unconfirmed_email, lengths: { unconfirmed_email: 191 })
    resize_columns_and_recreate_index(:users, :index_users_on_username, lengths: { username: 191 })

    # ==========
    # Following indexes exist in prod, not in dev
    # ==========

    create_index_unless_exists(:affiliate_credits, :oauth_application_id, :index_affiliate_credits_on_oauth_application_id)
    create_index_unless_exists(:events, :visit_id, :index_events_on_visit_id)
    create_index_unless_exists(:purchases, :ip_address, :index_purchases_on_ip_address)
    create_index_unless_exists(:purchases, :stripe_fingerprint, :index_purchases_on_stripe_fingerprint)

    # Special case: In dev, this there's an index named events.index_events_on_event_name_and_link_id which based on the columns [event_name, link_id].
    # In prod, an index with the SAME NAME is actually indexing [event_name, link_id, created_at].
    # MySQL 5.6 does not allow renaming of indexes, so we're recreating the index in dev to match the one in prod.
    if index_name_exists?(:events, :index_events_on_event_name_and_link_id, nil).columns.size == 2
      remove_index(:events, name: :index_events_on_event_name_and_link_id)
      add_index(:events, [:event_name, :link_id, :created_at], name: :index_events_on_event_name_and_link_id)
    end
  end

  def down
    # Irreversible by nature
  end

  def create_index_unless_exists(table_name, columns, index_name)
    return if index_name_exists?(table_name, index_name, nil)
    add_index(table_name, columns, name: index_name)
  end

  def recreate_index(table_name, columns, before:, after:)
    return unless index_name_exists?(table_name, before, nil)
    remove_index(table_name, name: before)
    add_index(table_name, columns, name: after)
  end

  def resize_columns_and_recreate_index(table_name, index_name, lengths:)
    index_definition = index_name_exists?(table_name, index_name, nil)
    return unless index_definition.columns == lengths.keys.map(&:to_s) && index_definition.lengths != lengths.values
    remove_index(table_name, name: index_name)
    lengths.each_pair do |column_name, length|
      next if length.nil?
      change_column(table_name, column_name, :string, limit: 255)
    end
    add_index(table_name, lengths.keys, name: index_name, length: lengths)
  end
end
