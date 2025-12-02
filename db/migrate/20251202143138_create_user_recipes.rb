class CreateUserRecipes < ActiveRecord::Migration[7.1]
  def change
    create_table :user_recipes do |t|
      t.string :recipe_name
      t.text :description
      t.text :content
      t.json :shopping_list
      t.string :prompt_summary
      t.boolean :favorite

      t.timestamps
    end
  end
end
