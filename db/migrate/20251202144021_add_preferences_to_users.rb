class AddPreferencesToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :Appliances, :text
    add_column :users, :allergies, :text
    add_column :users, :preferences, :text
    add_column :users, :physicals, :text
    add_column :users, :system_prompt, :text
  end
end
