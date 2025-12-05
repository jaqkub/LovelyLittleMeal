require "ruby_llm/schema"

# Schema definition for recipe responses from the LLM
# This schema ensures the LLM returns structured data matching the Recipe model
# Moved out of RecipesController to prevent redefinition issues in development mode
class RecipeSchema < RubyLLM::Schema
  string :title, description: "A concise, engaging title for the recipe"

  string :description, description: "A short, colorful description of the recipe to hook the reader"

  object :content do
    string :long_description,
           description: "A longer description of the recipe, written in a professional yet friendly tone"
    array :ingredients, of: :string,
                        description: "A list of ingredients needed, with quantities in metric units (e.g., '200g ingredient')"
    array :instructions, of: :string, description: "A numbered list of step-by-step instructions to prepare the recipe"
  end

  array :shopping_list, of: :string,
                        description: "A simple array of shopping items, each as a string with quantity and item name together. Example: [\"200g ingredient\", \"50g another ingredient\", \"2 pieces of produce\", \"15ml liquid\"]. Always include the quantity with metric units in each string."

  string :recipe_summary_for_prompt,
         description: "A concise text summary of the recipe, suitable for feeding into future prompts for recommendations"

  boolean :recipe_modified,
          description: "Set to true if you modified the recipe data (title, description, content, or shopping_list). Set to false if you are answering a question and returning the exact same recipe data unchanged. CRITICAL: This must be accurate - if you changed ANY recipe field, set to true. If you are just answering a question and returning identical recipe data, set to false."

  string :change_magnitude,
         description: "Indicates the magnitude of changes made to the recipe. Use 'significant' if ANY ingredients were added, removed, or changed (e.g., adding chocolate chips, removing an ingredient, replacing one ingredient with another). Use 'minor' ONLY for quantity adjustments (e.g., 'use 200g instead of 150g', 'reduce salt to 5g', 'double the recipe') where the same ingredients are used but amounts changed. Use 'none' if no changes were made (e.g., answering a question). CRITICAL: ANY ingredient addition/removal/replacement = 'significant' (requires image regeneration). ONLY pure quantity changes = 'minor' (no regeneration needed)."

  string :message,
         description: "A warm, encouraging message from a friendly chef persona about the created recipe. Structure: (1) Friendly introduction, (2) Factual mention of ONLY actual adjustments made if any (allergies removed/substituted, preference-based changes, appliance adaptations), (3) Encouraging closing, (4) Line break followed by 'Let me know if you need any adjustments!'. CRITICAL: Do NOT mention making a recipe 'nut-free' or 'allergen-free' if the original already didn't contain those allergens - only mention if you actually removed something. Do NOT mention 'used your available appliances' or 'aligned with preferences' if no changes were made. Only state what was changed, never what already matched. If no adjustments were needed, present the recipe warmly without mentioning adjustments/preferences/appliances/allergies. Always end with a line break and 'Let me know if you need any adjustments!'."
end
