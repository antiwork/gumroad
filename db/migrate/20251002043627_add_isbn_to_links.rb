class AddIsbnToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :isbn, :string, limit: 20
    add_index :links, :isbn
  end
end
