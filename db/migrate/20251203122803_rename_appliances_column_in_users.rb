class RenameAppliancesColumnInUsers < ActiveRecord::Migration[7.1]
  def change
    rename_column :users, :Appliances, :appliances
  end
end
