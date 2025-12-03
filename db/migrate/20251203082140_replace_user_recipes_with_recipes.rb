class ReplaceUserRecipesWithRecipes < ActiveRecord::Migration[7.1]
  def change
    # 1. Create the proper recipes table
    create_table :recipes do |t|
      t.string :title, null: false
      t.text :description, null: false
      t.jsonb :content, null: false, default: {}
      t.jsonb :shopping_list, null: false, default: []
      t.text :recipe_summary_for_prompt, null: false, default: ""
      t.boolean :favorite, null: false, default: false

      t.timestamps
    end

    add_index :recipes, :title
    add_index :recipes, [:title, :favorite]
    add_index :recipes, :content, using: :gin
    add_index :recipes, :shopping_list, using: :gin

    # 2. Add the new correct foreign key to chats
    add_reference :chats, :recipe, null: false, foreign_key: true

    # 3. Remove the old column + foreign key + table
    remove_reference :chats, :user_recipe, foreign_key: true
    drop_table :user_recipes
  end
end
