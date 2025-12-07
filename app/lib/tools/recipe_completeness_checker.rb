require "json"
require_relative "base_tool"
require_relative "error_classes"

# Validates that recipes have all required fields and are internally consistent
# Checks for missing fields, ingredient-instruction mismatches, and shopping list consistency
# Uses GPT-4.1-nano for fast completeness analysis
#
# This tool ensures recipes are complete and cookable before being returned to users
#
# Validation checks:
# - All required fields present (title, description, content, ingredients, instructions, shopping_list)
# - Ingredients mentioned in instructions match the ingredients list
# - Shopping list matches ingredients (all ingredients should be in shopping list)
# - Instructions are coherent and complete
module Tools
  class RecipeCompletenessChecker
    include BaseTool

    # Validates recipe completeness
    #
    # @param recipe_data [Hash] The recipe data to validate (from LLM response)
    # @return [ValidationResult] Validation result with violations and fix instructions
    def self.validate(recipe_data:)
      violations = []

      # First, check for missing required fields (fast, no LLM needed)
      missing_fields = check_missing_fields(recipe_data)
      violations.concat(missing_fields)

      # If critical fields are missing, return early
      if missing_fields.any? { |v| v[:type].to_s.start_with?("missing_required") }
        fix_instructions = generate_missing_fields_fix_instructions(missing_fields)
        return BaseTool.validation_result(
          valid: false,
          violations: violations,
          fix_instructions: fix_instructions
        )
      end

      # Extract structured data
      ingredients = extract_ingredients(recipe_data)
      instructions = extract_instructions(recipe_data)
      shopping_list = extract_shopping_list(recipe_data)

      # Check ingredient-instruction consistency using LLM
      # This is more reliable than regex matching for detecting ingredient mentions
      consistency_issues = check_ingredient_instruction_consistency(ingredients, instructions)

      # Check shopping list matches ingredients
      shopping_list_issues = check_shopping_list_consistency(ingredients, shopping_list)

      violations.concat(consistency_issues)
      violations.concat(shopping_list_issues)

      # Generate fix instructions
      fix_instructions = generate_fix_instructions(violations, ingredients, instructions, shopping_list)

      BaseTool.validation_result(
        valid: violations.empty?,
        violations: violations,
        fix_instructions: fix_instructions
      )
    rescue StandardError => e
      Rails.logger.error("RecipeCompletenessChecker: Error during validation: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      # Return a generic violation if validation fails
      BaseTool.validation_result(
        valid: false,
        violations: [BaseTool.violation(
          type: :validation_error,
          message: "Recipe completeness validation failed: #{e.message}",
          field: :general,
          fix_instruction: "Review the recipe structure and ensure all fields are properly formatted"
        )],
        fix_instructions: "Recipe validation encountered an error. Please review the recipe structure."
      )
    end

    private

    # Checks for missing required fields
    #
    # @param recipe_data [Hash] Recipe data
    # @return [Array<Hash>] Array of violation hashes
    def self.check_missing_fields(recipe_data)
      violations = []

      # Required top-level fields
      violations << BaseTool.violation(
        type: :missing_required_field,
        message: "Recipe is missing required field: title",
        field: :title,
        fix_instruction: "Add a title to the recipe"
      ) unless recipe_data["title"] || recipe_data[:title]

      violations << BaseTool.violation(
        type: :missing_required_field,
        message: "Recipe is missing required field: description",
        field: :description,
        fix_instruction: "Add a description to the recipe"
      ) unless recipe_data["description"] || recipe_data[:description]

      # Required content object fields
      content = recipe_data["content"] || recipe_data[:content] || {}
      if content.is_a?(Hash)
        violations << BaseTool.violation(
          type: :missing_required_field,
          message: "Recipe content is missing required field: ingredients",
          field: :ingredients,
          fix_instruction: "Add ingredients list to the recipe content"
        ) unless content["ingredients"] || content[:ingredients]

        violations << BaseTool.violation(
          type: :missing_required_field,
          message: "Recipe content is missing required field: instructions",
          field: :instructions,
          fix_instruction: "Add instructions to the recipe content"
        ) unless content["instructions"] || content[:instructions]
      else
        violations << BaseTool.violation(
          type: :missing_required_field,
          message: "Recipe is missing required field: content",
          field: :content,
          fix_instruction: "Add content object with ingredients and instructions"
        )
      end

      # Shopping list is recommended but not strictly required
      # (some recipes might not need a shopping list if all ingredients are common)

      violations
    end

    # Extracts ingredients from recipe data
    #
    # @param recipe_data [Hash] Recipe data
    # @return [Array<String>] Ingredients list
    def self.extract_ingredients(recipe_data)
      content = recipe_data["content"] || recipe_data[:content] || {}
      ingredients = content["ingredients"] || content[:ingredients] || []
      Array(ingredients)
    end

    # Extracts instructions from recipe data
    #
    # @param recipe_data [Hash] Recipe data
    # @return [Array<String>] Instructions list
    def self.extract_instructions(recipe_data)
      content = recipe_data["content"] || recipe_data[:content] || {}
      instructions = content["instructions"] || content[:instructions] || []
      Array(instructions)
    end

    # Extracts shopping list from recipe data
    #
    # @param recipe_data [Hash] Recipe data
    # @return [Array<String>] Shopping list
    def self.extract_shopping_list(recipe_data)
      shopping_list = recipe_data["shopping_list"] || recipe_data[:shopping_list] || []
      Array(shopping_list)
    end

    # Checks if ingredients mentioned in instructions match the ingredients list
    # Uses LLM for more reliable detection
    #
    # @param ingredients [Array<String>] Ingredients list
    # @param instructions [Array<String>] Instructions list
    # @return [Array<Hash>] Array of violation hashes
    def self.check_ingredient_instruction_consistency(ingredients, instructions)
      return [] if ingredients.empty? || instructions.empty?

      # Build analysis prompt
      analysis_prompt = build_consistency_prompt(ingredients, instructions)

      # Use GPT-4.1-nano for fast consistency analysis
      chat = RubyLLM.chat(model: "gpt-4.1-nano")
                     .with_instructions(consistency_instructions)

      # Ask for consistency analysis
      response = chat.ask(analysis_prompt).content

      # Parse response
      parse_consistency_response(response, ingredients, instructions)
    rescue StandardError => e
      Rails.logger.error("RecipeCompletenessChecker: Error checking consistency: #{e.message}")
      # Return empty violations if LLM fails (don't block recipe generation)
      []
    end

    # Builds consistency analysis instructions for LLM
    #
    # @return [String] Analysis instructions
    def self.consistency_instructions
      <<~INSTRUCTIONS
        You are analyzing a recipe to check if ingredients mentioned in instructions match the ingredients list.

        Your task:
        1. Read the ingredients list carefully
        2. Read each instruction step
        3. Identify any ingredients mentioned in instructions that are NOT in the ingredients list
        4. Identify any ingredients in the list that are NOT mentioned in any instruction
        5. Return a JSON object with:
           - "unmentioned_ingredients": Array of ingredient names from the list that aren't used in instructions
           - "extra_ingredients": Array of ingredient names mentioned in instructions but not in the list

        Be thorough but practical:
        - Ignore minor variations (e.g., "salt" vs "a pinch of salt")
        - Focus on actual ingredients, not quantities or cooking methods
        - Consider that some ingredients might be used implicitly (e.g., "oil" when "frying")

        Return ONLY valid JSON, no other text.
      INSTRUCTIONS
    end

    # Builds consistency analysis prompt
    #
    # @param ingredients [Array<String>] Ingredients list
    # @param instructions [Array<String>] Instructions list
    # @return [String] Analysis prompt
    def self.build_consistency_prompt(ingredients, instructions)
      <<~PROMPT
        Analyze the following recipe for ingredient-instruction consistency.

        Ingredients:
        #{ingredients.each_with_index.map { |ing, idx| "#{idx + 1}. #{ing}" }.join("\n")}

        Instructions:
        #{instructions.each_with_index.map { |inst, idx| "#{idx + 1}. #{inst}" }.join("\n")}

        Return a JSON object with:
        {
          "unmentioned_ingredients": ["ingredient1", "ingredient2", ...],
          "extra_ingredients": ["ingredient3", "ingredient4", ...]
        }

        If all ingredients are properly used and no extra ingredients are mentioned, return empty arrays.
      PROMPT
    end

    # Parses LLM response for consistency analysis
    #
    # @param response [String, Hash] LLM response
    # @param ingredients [Array<String>] Original ingredients list
    # @param instructions [Array<String>] Original instructions list
    # @return [Array<Hash>] Array of violation hashes
    def self.parse_consistency_response(response, ingredients, instructions)
      # Handle different response formats
      result = case response
               when String
                 begin
                   JSON.parse(response)
                 rescue JSON::ParserError
                   # Try to extract JSON from text
                   json_match = response.match(/\{[\s\S]*\}/)
                   json_match ? JSON.parse(json_match[0]) : {}
                 end
               when Hash
                 response
               else
                 {}
               end

      violations = []

      # Check for unmentioned ingredients
      unmentioned = Array(result["unmentioned_ingredients"] || result[:unmentioned_ingredients] || [])
      unmentioned.each do |ingredient|
        violations << BaseTool.violation(
          type: :ingredient_not_used,
          message: "Ingredient '#{ingredient}' is in the ingredients list but not mentioned in any instruction",
          field: :instructions,
          fix_instruction: "Add '#{ingredient}' to the appropriate instruction step(s) or remove it from the ingredients list if not needed"
        )
      end

      # Check for extra ingredients mentioned in instructions
      extra = Array(result["extra_ingredients"] || result[:extra_ingredients] || [])
      extra.each do |ingredient|
        violations << BaseTool.violation(
          type: :ingredient_missing_from_list,
          message: "Ingredient '#{ingredient}' is mentioned in instructions but not in the ingredients list",
          field: :ingredients,
          fix_instruction: "Add '#{ingredient}' to the ingredients list"
        )
      end

      violations
    end

    # Checks if shopping list matches ingredients
    # Uses simple matching (no LLM needed for this)
    #
    # @param ingredients [Array<String>] Ingredients list
    # @param shopping_list [Array<String>] Shopping list
    # @return [Array<Hash>] Array of violation hashes
    def self.check_shopping_list_consistency(ingredients, shopping_list)
      violations = []

      # Extract ingredient names (remove quantities for matching)
      ingredient_names = ingredients.map { |ing| normalize_ingredient_name(ing) }

      # Check each ingredient is in shopping list
      ingredient_names.each do |ingredient_name|
        # Check if this ingredient (or a close match) is in shopping list
        found = shopping_list.any? do |shopping_item|
          shopping_name = normalize_ingredient_name(shopping_item)
          # Check for exact match or contains match
          shopping_name.include?(ingredient_name) || ingredient_name.include?(shopping_name)
        end

        unless found
          violations << BaseTool.violation(
            type: :ingredient_missing_from_shopping_list,
            message: "Ingredient '#{ingredient_name}' is in the ingredients list but not in the shopping list",
            field: :shopping_list,
            fix_instruction: "Add '#{ingredient_name}' to the shopping list"
          )
        end
      end

      violations
    end

    # Normalizes ingredient name for matching (removes quantities, converts to lowercase)
    #
    # @param ingredient [String] Ingredient string (e.g., "200g flour")
    # @return [String] Normalized ingredient name (e.g., "flour")
    def self.normalize_ingredient_name(ingredient)
      # Remove quantities (numbers, units like g, ml, kg, etc.)
      normalized = ingredient.to_s
                            .gsub(/\d+[.,]?\d*\s*(g|kg|ml|l|pieces?|pcs?|tsp|tbsp|cups?|pinch|dash|clove|head|bunch)/i, "")
                            .gsub(/\d+/, "")
                            .strip
                            .downcase

      # Remove common prefixes/suffixes
      normalized.gsub(/\b(a|an|the|some|few|several)\s+/i, "")
                .strip
    end

    # Generates fix instructions for missing fields
    #
    # @param missing_fields [Array<Hash>] Missing field violations
    # @return [String] Fix instructions
    def self.generate_missing_fields_fix_instructions(missing_fields)
      return "No missing fields." if missing_fields.empty?

      instructions = []
      instructions << "CRITICAL: The recipe is missing required fields."
      instructions << ""
      instructions << "Missing fields:"
      missing_fields.each do |violation|
        instructions << "  - #{violation[:field]}: #{violation[:message]}"
      end
      instructions << ""
      instructions << "Fix instructions:"
      instructions << "1. Add all missing required fields to the recipe"
      instructions << "2. Ensure the recipe structure matches the RecipeSchema format"
      instructions << "3. Verify all fields are properly formatted"

      instructions.join("\n")
    end

    # Generates comprehensive fix instructions for all violations
    #
    # @param violations [Array<Hash>] All violations
    # @param ingredients [Array<String>] Ingredients list
    # @param instructions [Array<String>] Instructions list
    # @param shopping_list [Array<String>] Shopping list
    # @return [String] Fix instructions
    def self.generate_fix_instructions(violations, ingredients, instructions, shopping_list)
      return "Recipe is complete and consistent." if violations.empty?

      instructions_text = []
      instructions_text << "CRITICAL: The recipe has completeness and consistency issues."
      instructions_text << ""

      # Group violations by type
      missing_fields = violations.select { |v| v[:type].to_s.start_with?("missing_required") }
      consistency_issues = violations.select { |v| v[:type].to_s.start_with?("ingredient_") }

      if missing_fields.any?
        instructions_text << "Missing Required Fields:"
        missing_fields.each do |violation|
          instructions_text << "  - #{violation[:message]}"
        end
        instructions_text << ""
      end

      if consistency_issues.any?
        instructions_text << "Ingredient Consistency Issues:"
        consistency_issues.each do |violation|
          instructions_text << "  - #{violation[:message]}"
        end
        instructions_text << ""
      end

      instructions_text << "Fix instructions:"
      instructions_text << "1. Add all missing required fields"
      instructions_text << "2. Ensure all ingredients in the list are mentioned in instructions"
      instructions_text << "3. Ensure all ingredients mentioned in instructions are in the ingredients list"
      instructions_text << "4. Ensure all ingredients are in the shopping list"
      instructions_text << "5. Review the recipe for completeness and consistency"

      instructions_text.join("\n")
    end
  end
end

