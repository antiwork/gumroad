class AddFirebaseUidToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :firebase_uid, :string
  end
end
