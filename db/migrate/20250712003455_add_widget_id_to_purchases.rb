class AddWidgetIdToPurchases < ActiveRecord::Migration[7.1]
  def change
    add_column :purchases, :widget_id, :string
    add_index :purchases, :widget_id
  end
end
