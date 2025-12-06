require_relative "base_tool"
require_relative "error_classes"

# Validates that allergen warnings are present and correctly formatted in recipe instructions
# This tool addresses the critical issue where allergen warnings sometimes don't appear
# Uses pure Ruby validation (no LLM call) for 100% reliability
#
# Validation checks:
# - Warning emoji (⚠️) must be present in the instruction step where the allergen is added
# - Warning must mention specific allergen from user's allergy list (not generic)
# - Warning must appear in the same instruction step or immediately adjacent to where allergen is mentioned
#
# Returns structured validation result with specific fix instructions if violations found
module Tools
  class AllergenWarningValidator
    include BaseTool

    # Validates allergen warning in recipe instructions
    #
    # @param instructions [Array<String>] The recipe instructions array to validate
    # @param user_allergies [Array<String>, String] List of user's allergies (e.g., ["nuts", "dairy"] or "nuts, dairy")
    # @param requested_ingredients [Array<String>] Ingredients that were explicitly requested (may contain allergens)
    # @return [ValidationResult] Validation result with violations and fix instructions
    def self.validate(instructions:, user_allergies:, requested_ingredients: [])
      violations = []
      instructions = Array(instructions) # Ensure it's an array

      # Normalize user_allergies to array format (handles both string and array)
      user_allergies = normalize_allergies(user_allergies)

      # Check if any requested ingredients match user allergies
      # If no allergens were requested, no warning is needed
      requested_allergens = find_requested_allergens(requested_ingredients, user_allergies)

      return BaseTool.validation_result(valid: true, violations: []) if requested_allergens.empty?

      # Find which instruction step(s) mention the allergen ingredient
      allergen_instruction_indices = find_allergen_instruction_steps(instructions, requested_ingredients,
                                                                     user_allergies)

      if allergen_instruction_indices.empty?
        # Allergen not found in instructions - this might be a new recipe where allergen is in ingredients list
        # In this case, check if warning appears in any instruction step
        violations << BaseTool.violation(
          type: :allergen_not_in_instructions,
          message: "Requested allergen ingredient not found in instructions - ensure it's added to a step",
          field: :instructions,
          fix_instruction: "Add the allergen ingredient to the appropriate instruction step"
        )
      else
        # Check each instruction step that mentions the allergen
        allergen_instruction_indices.each do |step_index|
          instruction = instructions[step_index]
          step_number = step_index + 1

          # Check for warning emoji in this step or adjacent steps
          warning_found = check_warning_in_step_range(instructions, step_index)

          # Check if warning format is correct (capitalized "WARNING:")
          warning_format_correct = false
          if warning_found
            # Check if the step with warning has the correct format
            steps_to_check = [
              step_index - 1,
              step_index,
              step_index + 1
            ].select { |idx| idx >= 0 && idx < instructions.length }

            warning_format_correct = steps_to_check.any? do |idx|
              step = instructions[idx]
              step.include?("⚠️") && step.include?("WARNING:")
            end
          end

          unless warning_found
            violations << BaseTool.violation(
              type: :missing_emoji,
              message: "Warning emoji (⚠️) is missing from instruction step #{step_number} where allergen is added",
              field: :instructions,
              fix_instruction: "Add the warning emoji (⚠️) and capitalized 'WARNING:' to instruction step #{step_number} where the allergen is added"
            )
          end

          # Check if warning format is correct (must have capitalized "WARNING:")
          if warning_found && !warning_format_correct
            violations << BaseTool.violation(
              type: :incorrect_warning_format,
              message: "Warning in step #{step_number} does not have capitalized 'WARNING:' format. Must start with '⚠️ WARNING:' (capitalized)",
              field: :instructions,
              fix_instruction: "Ensure instruction step #{step_number} starts with '⚠️ WARNING:' (capitalized, not 'warning' or 'Warning')"
            )
          end

          # Check for personalized warning (mentions specific allergen)
          allergen_names = extract_allergen_names(requested_allergens)
          missing_allergen_mentions = allergen_names.reject do |name|
            instruction.downcase.include?(name.downcase)
          end

          # Also check adjacent steps for allergen mention
          if missing_allergen_mentions.any?
            adjacent_steps = get_adjacent_steps(instructions, step_index)
            missing_allergen_mentions = missing_allergen_mentions.reject do |name|
              adjacent_steps.any? { |step| step.downcase.include?(name.downcase) }
            end
          end

          next unless missing_allergen_mentions.any?

          violations << BaseTool.violation(
            type: :generic_warning,
            message: "Warning in step #{step_number} does not mention specific allergen(s): #{missing_allergen_mentions.join(', ')}",
            field: :instructions,
            fix_instruction: "Mention the specific allergen(s) '#{missing_allergen_mentions.join(', ')}' in the warning text for step #{step_number}"
          )
        end
      end

      # Generate fix instructions
      fix_instructions = generate_fix_instructions(requested_allergens, violations, allergen_instruction_indices)

      BaseTool.validation_result(
        valid: violations.empty?,
        violations: violations,
        fix_instructions: fix_instructions
      )
    end

    private

    # Finds which requested ingredients match user allergies
    # Returns array of [allergen_name, ingredient_name] pairs for better context
    def self.find_requested_allergens(requested_ingredients, user_allergies)
      return [] if requested_ingredients.empty? || user_allergies.empty?

      # Normalize user_allergies to array (handles both string and array formats)
      # Allergies can be stored as comma-separated string or array
      user_allergies = normalize_allergies(user_allergies)
      return [] if user_allergies.empty?

      requested_allergens = []
      requested_lower = requested_ingredients.map(&:downcase)
      allergies_lower = user_allergies.map(&:downcase)

      # Check for direct matches
      requested_ingredients.each_with_index do |ingredient, idx|
        ingredient_lower = requested_lower[idx]
        allergies_lower.each_with_index do |allergy, allergy_idx|
          # Check if ingredient contains allergy or vice versa
          # e.g., "peanuts" matches "nuts" allergy, "peanut butter" matches "nuts"
          next unless ingredient_lower.include?(allergy) || allergy.include?(ingredient_lower) ||
                      ingredient_lower.split.any?(allergy) ||
                      allergy.split.any?(ingredient_lower)

          # Store both the allergen name and the ingredient that triggered it
          # Format: "allergen_name (ingredient_name)" for clarity
          allergen_name = user_allergies[allergy_idx]
          if ingredient_lower == allergy
            requested_allergens << allergen_name
          else
            requested_allergens << "#{allergen_name} (#{ingredient})"
          end
        end
      end

      requested_allergens.uniq
    end

    # Finds which instruction steps mention the allergen ingredient
    # Returns array of step indices (0-based) where allergen is mentioned
    def self.find_allergen_instruction_steps(instructions, requested_ingredients, user_allergies)
      indices = []
      requested_allergens = find_requested_allergens(requested_ingredients, user_allergies)
      return [] if requested_allergens.empty?

      # Extract ingredient names from requested allergens
      # Format can be "allergen (ingredient)" or just "allergen"
      ingredient_names = requested_allergens.map do |item|
        if item.include?("(")
          # Extract ingredient name from "allergen (ingredient)"
          item.split("(").last.delete(")").strip
        else
          # If no ingredient specified, use allergen name
          item
        end
      end.uniq

      instructions.each_with_index do |instruction, index|
        instruction_lower = instruction.downcase
        ingredient_names.each do |ingredient_name|
          ingredient_lower = ingredient_name.downcase
          # Check if instruction mentions the ingredient
          # Use word boundaries to avoid partial matches (e.g., "peanut" should match "peanuts" but not "peanut butter" as separate words)
          # But also allow partial matches for compound words
          matches = instruction_lower.include?(ingredient_lower) ||
                    ingredient_lower.split.any? { |word| instruction_lower.include?(word) } ||
                    # Handle plural forms (peanut -> peanuts)
                    (ingredient_lower.end_with?("s") && instruction_lower.include?(ingredient_lower[0..-2])) ||
                    (!ingredient_lower.end_with?("s") && instruction_lower.include?("#{ingredient_lower}s"))

          if matches
            indices << index unless indices.include?(index) # Avoid duplicates
            break # Found in this step, move to next ingredient check
          end
        end
      end

      indices
    end

    # Checks if warning emoji appears in the specified step or adjacent steps
    # Returns true if warning found, false otherwise
    # Also checks if the warning format is correct (capitalized "WARNING:")
    def self.check_warning_in_step_range(instructions, step_index)
      # Check the step itself and adjacent steps (one before, one after)
      steps_to_check = [
        step_index - 1,
        step_index,
        step_index + 1
      ].select { |idx| idx >= 0 && idx < instructions.length }

      # Check if warning emoji exists AND format is correct (capitalized "WARNING:")
      steps_to_check.any? do |idx|
        step = instructions[idx]
        step.include?("⚠️") && step.include?("WARNING:")
      end
    end

    # Gets adjacent instruction steps (for checking allergen mentions)
    def self.get_adjacent_steps(instructions, step_index)
      steps = []
      steps << instructions[step_index - 1] if step_index > 0
      steps << instructions[step_index]
      steps << instructions[step_index + 1] if step_index < instructions.length - 1
      steps.compact
    end

    # Extracts allergen names from requested allergens array
    # Handles format "allergen (ingredient)" or just "allergen"
    def self.extract_allergen_names(requested_allergens)
      requested_allergens.map do |item|
        if item.include?("(")
          parts = item.split("(")
          [parts[0].strip, parts[1].delete(")").strip]
        else
          [item]
        end
      end.flatten.uniq
    end

    # Generates comprehensive fix instructions based on violations
    def self.generate_fix_instructions(requested_allergens, violations, allergen_step_indices = [])
      return nil if violations.empty?

      instructions = []

      missing_emoji_violations = violations.select { |v| v[:type] == :missing_emoji }
      if missing_emoji_violations.any?
        step_numbers = missing_emoji_violations.filter_map { |v| v[:field] == :instructions ? "step" : nil }
        if allergen_step_indices.any?
          step_nums = allergen_step_indices.map { |idx| idx + 1 }.join(", ")
          instructions << "Add the warning emoji (⚠️) to instruction step(s) #{step_nums} where the allergen is added"
        else
          instructions << "Add the warning emoji (⚠️) to the instruction step where the allergen is added"
        end
      end

      generic_violation = violations.find { |v| v[:type] == :generic_warning }
      if generic_violation
        allergen_list = requested_allergens.map do |item|
          # Extract just the allergen name (before parenthesis if present)
          item.include?("(") ? item.split("(").first.strip : item
        end.join(" and ")

        if allergen_step_indices.any?
          step_nums = allergen_step_indices.map { |idx| idx + 1 }.join(", ")
          instructions << "Include a personalized warning in step(s) #{step_nums} that mentions the specific allergen(s): #{allergen_list}"
        else
          instructions << "Include a personalized warning that mentions the specific allergen(s): #{allergen_list}"
        end
      end

      # Generate example format
      allergen_list = requested_allergens.map do |item|
        item.include?("(") ? item.split("(").first.strip : item
      end.join(" and ")
      example_format = "⚠️ WARNING: This step contains #{allergen_list} which you are allergic to. Proceed with extreme caution"

      instructions << "Example format for the instruction step: \"#{example_format}\""

      instructions.join(". ")
    end

    # Normalizes allergies from various formats to array
    # Handles:
    # - Hash format: { "peanut" => true, "tree_nuts" => false } -> ["peanut"]
    # - Comma-separated strings: "nuts, dairy" -> ["nuts", "dairy"]
    # - Arrays: ["nuts", "dairy"] -> ["nuts", "dairy"]
    #
    # @param allergies [Hash, String, Array<String>] Allergies in various formats
    # @return [Array<String>] Normalized array of active allergy keys
    def self.normalize_allergies(allergies)
      return [] if allergies.blank?

      case allergies
      when Hash
        # Extract keys where value is true
        allergies.select { |_key, value| value == true }.keys.map(&:to_s)
      when Array
        allergies.reject(&:blank?).map(&:to_s)
      when String
        # Split by comma and clean up whitespace
        allergies.split(",").map(&:strip).reject(&:blank?).map(&:to_s)
      else
        # Try to convert to array
        Array(allergies).reject(&:blank?).map(&:to_s)
      end
    end

    class << self
      private :find_requested_allergens, :find_allergen_instruction_steps,
              :check_warning_in_step_range, :get_adjacent_steps,
              :extract_allergen_names, :generate_fix_instructions, :normalize_allergies
    end
  end
end
