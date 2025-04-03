# frozen_string_literal: true

class RenameOauthApplicationOwnerIdToAffiliateUserId < ActiveRecord::Migration
  def up
    remove_index :affiliate_credits, name: "index_affiliate_credits_on_oauth_application_owner_id"
    rename_column :affiliate_credits, :oauth_application_owner_id, :affiliate_user_id
    add_index :affiliate_credits, :affiliate_user_id
  end

  def down
    remove_index :affiliate_credits, name: "index_affiliate_credits_on_affiliate_user_id"
    rename_column :affiliate_credits, :affiliate_user_id, :oauth_application_owner_id
    add_index :affiliate_credits, :oauth_application_owner_id
  end
end
