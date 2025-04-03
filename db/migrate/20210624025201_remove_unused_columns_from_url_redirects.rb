# frozen_string_literal: true

class RemoveUnusedColumnsFromUrlRedirects < ActiveRecord::Migration[6.1]
  def up
    execute <<~SQL
      ALTER TABLE `url_redirects`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
      DROP COLUMN `webhooked_url`,
      DROP COLUMN `customized_file_url`,
      CHANGE `id` `id` bigint NOT NULL AUTO_INCREMENT,
      CHANGE `purchase_id` `purchase_id` bigint DEFAULT NULL,
      CHANGE `link_id` `link_id` bigint DEFAULT NULL,
      CHANGE `installment_id` `installment_id` bigint DEFAULT NULL,
      CHANGE `subscription_id` `subscription_id` bigint DEFAULT NULL,
      CHANGE `preorder_id` `preorder_id` bigint DEFAULT NULL,
      CHANGE `imported_customer_id` `imported_customer_id` bigint DEFAULT NULL,
      CHANGE `token` `token` varchar(255) DEFAULT NULL
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE `url_redirects`
      CHARACTER SET utf8 COLLATE utf8_unicode_ci,
      ADD COLUMN `webhooked_url` text COLLATE utf8_unicode_ci AFTER `token`,
      ADD COLUMN `customized_file_url` varchar(255) COLLATE utf8_unicode_ci DEFAULT NULL AFTER `link_id`,
      CHANGE `id` `id` int(11) NOT NULL AUTO_INCREMENT,
      CHANGE `purchase_id` `purchase_id` int(11) DEFAULT NULL,
      CHANGE `link_id` `link_id` int(11) DEFAULT NULL,
      CHANGE `installment_id` `installment_id` int(11) DEFAULT NULL,
      CHANGE `subscription_id` `subscription_id` int(11) DEFAULT NULL,
      CHANGE `preorder_id` `preorder_id` int(11) DEFAULT NULL,
      CHANGE `imported_customer_id` `imported_customer_id` int(11) DEFAULT NULL,
      CHANGE `token` `token` varchar(255) COLLATE utf8_unicode_ci DEFAULT NULL
    SQL
  end
end
