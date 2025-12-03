require "ruby_llm/schema"

# Schema definition for recipe responses from the LLM
# This schema ensures the LLM returns structured data matching the Recipe model
# Moved out of RecipesController to prevent redefinition issues in development mode
class RecipeSchema < RubyLLM::Schema
  string :title, description: "A concise, engaging title for the recipe"

  string :description, description: "A short, colorful description of the recipe to hook the reader"

  object :content do
    string :long_description, description: "A longer description of the recipe, written in a professional yet friendly tone"
    array :ingredients, of: :string, description: "A list of ingredients needed, with quantities in metric units (e.g., '200g flour')"
    array :instructions, of: :string, description: "A numbered list of step-by-step instructions to prepare the recipe"
  end

  array :shopping_list, of: :string, description: "A simple array of shopping items, each as a string with quantity and item name together. Example: [\"200g flour\", \"50g sugar\", \"2 ripe bananas\", \"15ml coconut oil\"]. Always include the quantity with metric units in each string."

  string :recipe_summary_for_prompt, description: "A concise text summary of the recipe, suitable for feeding into future prompts for recommendations"

  string :message, description: "A short, in-character message to the user about the created recipe"
end

