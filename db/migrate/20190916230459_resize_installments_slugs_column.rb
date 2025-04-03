# frozen_string_literal: true

class ResizeInstallmentsSlugsColumn < ActiveRecord::Migration
  def up
    safety_assured do
      execute "ALTER TABLE `installments` CHANGE `slug` `slug` varchar(255) NULL COMMENT '';"
    end
  end

  def down
    safety_assured do
      execute "ALTER TABLE `installments` CHANGE `slug` `slug` varchar(191) NULL COMMENT '';"
    end
  end
end
