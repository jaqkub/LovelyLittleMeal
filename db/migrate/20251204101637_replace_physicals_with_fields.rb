class ReplacePhysicalsWithFields < ActiveRecord::Migration[7.1]
  def change
    remove_column :users, :physicals, :text

    add_column :users, :age, :integer
    add_column :users, :weight, :integer
    add_column :users, :gender, :boolean
  end
end
