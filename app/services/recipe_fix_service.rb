# Service for automatically fixing recipe validation violations
# Uses programmatic fixes for simple violations (fast, reliable, free)
# Falls back to LLM fixes only for complex violations that require rephrasing
#
# This addresses the issue where violations are detected but not automatically fixed,
# ensuring critical requirements (like allergen warnings) are met before returning
class RecipeFixService
  MAX_ITERATIONS = 3

  # Fixes recipe violations using programmatic fixes first, then LLM if needed
  #
  # @param recipe_data [Hash] Current recipe data from LLM
  # @param violations [Array<Hash>] Array of violation hashes from validators
  # @param user_message [Message] The original user message
  # @param chat [Chat] The chat instance
  # @param current_user [User] The current user
  # @param ruby_llm_chat [RubyLLM::Chat] The RubyLLM chat instance with conversation history
  # @return [Hash] Fixed recipe data or original if no violations
  def self.fix_violations(recipe_data:, violations:, user_message:, chat:, current_user:, ruby_llm_chat:)
    return recipe_data if violations.empty?

    Rails.logger.info("RecipeFixService: Starting fix process with #{violations.length} violation(s)")

    # Separate violations into programmatically fixable vs LLM-required
    programmatic_violations, llm_violations = separate_violations(violations)

    # Try programmatic fixes first (fast, reliable, free)
    if programmatic_violations.any?
      Rails.logger.info("RecipeFixService: Attempting programmatic fixes for #{programmatic_violations.length} violation(s)")
      recipe_data = apply_programmatic_fixes(
        recipe_data: recipe_data,
        violations: programmatic_violations,
        user_message: user_message,
        current_user: current_user
      )

      # Re-validate after programmatic fixes
      validation_result = validate_fixed_recipe(
        recipe_data: recipe_data,
        user_message: user_message,
        current_user: current_user
      )

      # If programmatic fixes resolved everything, return
      if validation_result.valid?
        Rails.logger.info("RecipeFixService: ✅ All violations fixed programmatically (no LLM call needed)")
        return recipe_data
      end

      # Update violations list with remaining violations
      llm_violations = validation_result.violations
      Rails.logger.info("RecipeFixService: Programmatic fixes resolved some violations, #{llm_violations.length} remaining")
    end

    # Fall back to LLM fixes for complex violations
    if llm_violations.any?
      Rails.logger.info("RecipeFixService: Using LLM fixes for #{llm_violations.length} complex violation(s)")
      recipe_data = fix_with_llm(
        recipe_data: recipe_data,
        violations: llm_violations,
        user_message: user_message,
        current_user: current_user,
        ruby_llm_chat: ruby_llm_chat
      )
    end

    recipe_data
  end

  private

  # Separates violations into programmatically fixable vs LLM-required
  #
  # @param violations [Array<Hash>] Array of violation hashes
  # @return [Array<Array<Hash>, Array<Hash>>] [programmatic_violations, llm_violations]
  def self.separate_violations(violations)
    programmatic = []
    llm_required = []

    violations.each do |violation|
      case violation[:type]
      when :missing_emoji, :incorrect_warning_format
        # These can be fixed programmatically by inserting/updating warning text
        programmatic << violation
      when :generic_warning
        # Can be fixed by updating the warning text to include allergen name
        programmatic << violation
      when :non_metric_unit_in_ingredients, :non_metric_unit_in_shopping_list, :unrealistic_shopping_amount
        # Can be fixed programmatically by applying converted values
        programmatic << violation
      when :allergen_not_in_instructions
        # Requires LLM to add allergen to appropriate step
        llm_required << violation
      else
        # Unknown violation type - use LLM to be safe
        llm_required << violation
      end
    end

    [programmatic, llm_required]
  end

  # Applies programmatic fixes to recipe data
  #
  # @param recipe_data [Hash] Current recipe data
  # @param violations [Array<Hash>] Violations to fix programmatically
  # @param user_message [Message] Original user message
  # @param current_user [User] Current user
  # @return [Hash] Fixed recipe data
  def self.apply_programmatic_fixes(recipe_data:, violations:, user_message:, current_user:)
    fixed_data = recipe_data.deep_dup
    instructions = fixed_data.dig("content", "instructions") || []

    # Get user allergies for warning text
    user_allergies = if current_user.allergies.is_a?(Hash)
                       current_user.active_allergies
                     else
                       []
                     end

    # Extract requested ingredients to determine which allergen to mention
    requested_ingredients = extract_requested_ingredients(user_message.content)
    requested_allergens = Tools::AllergenWarningValidator.send(
      :find_requested_allergens,
      requested_ingredients,
      user_allergies
    )

    # Find which steps need warnings
    allergen_step_indices = Tools::AllergenWarningValidator.send(
      :find_allergen_instruction_steps,
      instructions,
      requested_ingredients,
      user_allergies
    )

    # Get allergen name for warning text
    allergen_name = extract_allergen_name_for_warning(requested_allergens, user_allergies)

    # Separate violations by type
    allergen_violations = violations.select { |v| [:missing_emoji, :incorrect_warning_format, :generic_warning].include?(v[:type]) }
    shopping_list_violations = violations.select { |v| [:non_metric_unit_in_shopping_list, :unrealistic_shopping_amount].include?(v[:type]) }
    ingredient_violations = violations.select { |v| v[:type] == :non_metric_unit_in_ingredients }

    # Fix shopping list violations programmatically (using converted data from validator)
    if shopping_list_violations.any?
      # Get converted shopping list from the first violation (they all have the same converted data)
      converted_shopping_list = shopping_list_violations.first[:converted_data]&.dig(:shopping_list)
      if converted_shopping_list && converted_shopping_list.any?
        fixed_data["shopping_list"] = converted_shopping_list
        Rails.logger.info("RecipeFixService: Programmatically fixed shopping list (#{shopping_list_violations.length} violation(s))")
        Rails.logger.info("RecipeFixService: Shopping list updated to: #{converted_shopping_list.inspect}")
      end
    end

    # Fix ingredient violations programmatically (using converted data from validator)
    if ingredient_violations.any?
      # Get converted ingredients from the first violation
      converted_ingredients = ingredient_violations.first[:converted_data]&.dig(:ingredients)
      if converted_ingredients && converted_ingredients.any?
        fixed_data["content"] ||= {}
        fixed_data["content"]["ingredients"] = converted_ingredients
        Rails.logger.info("RecipeFixService: Programmatically fixed ingredients (#{ingredient_violations.length} violation(s))")
      end
    end

    # Fix allergen warning violations (only if we have instructions)
    if allergen_violations.any? && instructions.any?
    # Group violations by step number
      violations_by_step = allergen_violations.group_by do |violation|
      step_match = violation[:message].match(/step (\d+)/i)
      step_match ? step_match[1].to_i - 1 : nil # Convert to 0-based index
    end

    # Fix each step
    violations_by_step.each do |step_index, step_violations|
      next unless step_index && step_index >= 0 && step_index < instructions.length

      instruction = instructions[step_index].dup
      original_instruction = instruction.dup

      step_violations.each do |violation|
        case violation[:type]
        when :missing_emoji
          # Prepend warning to instruction step
          # Only add if not already present
          unless instruction.include?("⚠️") && instruction.include?("WARNING:")
            warning_text = "⚠️ WARNING: This step contains #{allergen_name} which you are allergic to. Proceed with extreme caution. "
            instruction = warning_text + instruction
            Rails.logger.info("RecipeFixService: Programmatically added warning to step #{step_index + 1}")
          end

        when :incorrect_warning_format
          # Fix capitalization of WARNING
          instruction = instruction.gsub(/⚠️\s*(warning|Warning):/i, "⚠️ WARNING:")
          if instruction != original_instruction
            Rails.logger.info("RecipeFixService: Programmatically fixed WARNING format in step #{step_index + 1}")
          end

        when :generic_warning
          # Update warning to include specific allergen name
          if instruction.include?("⚠️") && instruction.include?("WARNING:")
            # Replace generic warning text with specific allergen
            # Pattern: "⚠️ WARNING: [generic text]. [rest of instruction]"
            # Replace with: "⚠️ WARNING: This step contains [allergen] which you are allergic to. Proceed with extreme caution. [rest]"
            instruction = instruction.sub(
              /(⚠️\s*WARNING:\s*)[^.]*(\.\s*)/i,
              "\\1This step contains #{allergen_name} which you are allergic to. Proceed with extreme caution. "
            )
            Rails.logger.info("RecipeFixService: Programmatically updated warning to include specific allergen in step #{step_index + 1}")
          end
        end
      end

      instructions[step_index] = instruction
    end

    # Update recipe data with fixed instructions
    fixed_data["content"] ||= {}
    fixed_data["content"]["instructions"] = instructions
    end

    fixed_data
  end

  # Extracts allergen name for warning text
  # Cleans up ingredient names to remove filler words and use proper allergen names
  #
  # @param requested_allergens [Array<String>] Requested allergens (may include ingredient in parentheses)
  # @param user_allergies [Array<String>] User's active allergies
  # @return [String] Formatted allergen name for warning
  def self.extract_allergen_name_for_warning(requested_allergens, user_allergies)
    return "the allergen" if requested_allergens.empty?

    # Filler words to remove from ingredient names
    filler_words = %w[anyway please add with to the a an some more]

    # Extract allergen names (handle "allergen (ingredient)" format)
    allergen_names = requested_allergens.map do |item|
      if item.include?("(")
        # Format: "sesame (sesame anyway)" -> "sesame (Sesame)"
        parts = item.split("(")
        allergen = parts[0].strip
        ingredient = parts[1].delete(")").strip
        
        # Clean up ingredient name - remove filler words and normalize
        cleaned_ingredient = clean_ingredient_name(ingredient, filler_words)
        
        # If cleaned ingredient matches allergen, just use allergen name
        if cleaned_ingredient.downcase == allergen.downcase || cleaned_ingredient.downcase.include?(allergen.downcase)
          format_allergen_name(allergen)
        else
          # Format for display: "peanuts (tree nuts)" or just "sesame" if they match
          "#{cleaned_ingredient} (#{format_allergen_name(allergen)})"
        end
      else
        # Clean up the allergen name itself
        cleaned = clean_ingredient_name(item, filler_words)
        format_allergen_name(cleaned)
      end
    end

    # Join multiple allergens
    if allergen_names.length == 1
      allergen_names.first
    else
      "#{allergen_names[0..-2].join(', ')} and #{allergen_names.last}"
    end
  end

  # Cleans ingredient names by removing filler words and normalizing
  #
  # @param ingredient [String] Raw ingredient name (e.g., "sesame anyway")
  # @param filler_words [Array<String>] Words to remove
  # @return [String] Cleaned ingredient name (e.g., "sesame")
  def self.clean_ingredient_name(ingredient, filler_words = [])
    return ingredient if ingredient.blank?

    # Split into words, remove filler words, and rejoin
    words = ingredient.split
    cleaned_words = words.reject { |word| filler_words.include?(word.downcase) }
    
    # If we removed all words, return the original (shouldn't happen, but safety check)
    return ingredient if cleaned_words.empty?
    
    cleaned_words.join(" ").strip
  end

  # Formats allergen key to human-readable name
  #
  # @param key [String] Allergen key (e.g., "tree_nuts")
  # @return [String] Formatted name (e.g., "tree nuts")
  def self.format_allergen_name(key)
    key.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end

  # Fixes violations using LLM (for complex cases that can't be fixed programmatically)
  #
  # @param recipe_data [Hash] Current recipe data
  # @param violations [Array<Hash>] Violations requiring LLM fixes
  # @param user_message [Message] Original user message
  # @param current_user [User] Current user
  # @param ruby_llm_chat [RubyLLM::Chat] RubyLLM chat instance
  # @return [Hash] Fixed recipe data
  def self.fix_with_llm(recipe_data:, violations:, user_message:, current_user:, ruby_llm_chat:)
    fix_instructions = aggregate_fix_instructions(violations)
    iteration = 0
    fixed_recipe_data = recipe_data

    while iteration < MAX_ITERATIONS
      iteration += 1
      Rails.logger.info("RecipeFixService: LLM fix iteration #{iteration}/#{MAX_ITERATIONS}")
      Rails.logger.info("RecipeFixService: Current violations to fix:")
      violations.each_with_index do |violation, idx|
        Rails.logger.info("  #{idx + 1}. #{violation[:type]}: #{violation[:message]}")
      end

      # Build fix prompt with violations and instructions
      fix_prompt = build_fix_prompt(
        recipe_data: fixed_recipe_data,
        fix_instructions: fix_instructions,
        user_message: user_message
      )

      # Request fix from LLM
      begin
        fixed_response = ruby_llm_chat.ask(fix_prompt).content

        # Log the fixed instructions for debugging
        fixed_instructions = fixed_response.dig("content", "instructions") || []
        Rails.logger.info("RecipeFixService: Fixed recipe instructions after LLM iteration #{iteration}:")
        fixed_instructions.each_with_index do |instruction, idx|
          has_warning = instruction.include?("⚠️")
          has_capitalized_warning = instruction.include?("WARNING:")
          Rails.logger.info("  Step #{idx + 1}: #{has_warning ? '✅' : '❌'} Warning emoji, #{has_capitalized_warning ? '✅' : '❌'} Capitalized WARNING")
          Rails.logger.info("    #{instruction[0..100]}#{instruction.length > 100 ? '...' : ''}")
        end

        # Validate the fixed recipe
        validation_result = validate_fixed_recipe(
          recipe_data: fixed_response,
          user_message: user_message,
          current_user: current_user
        )

        # If no violations, return fixed recipe
        if validation_result.valid?
          Rails.logger.info("RecipeFixService: ✅ All violations fixed after LLM iteration #{iteration}")
          return fixed_response
        end

        # Log remaining violations
        Rails.logger.warn("RecipeFixService: LLM iteration #{iteration} still has #{validation_result.violations.length} violation(s):")
        validation_result.violations.each_with_index do |violation, idx|
          Rails.logger.warn("  #{idx + 1}. #{violation[:type]}: #{violation[:message]}")
        end

        # Update recipe data for next iteration
        fixed_recipe_data = fixed_response
        fix_instructions = aggregate_fix_instructions(validation_result.violations)
        violations = validation_result.violations

        Rails.logger.warn("RecipeFixService: Continuing to LLM iteration #{iteration + 1}...")
      rescue StandardError => e
        Rails.logger.error("RecipeFixService: Error in LLM fix iteration #{iteration}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        # Continue to next iteration or return original
        break if iteration >= MAX_ITERATIONS
      end
    end

    Rails.logger.warn("RecipeFixService: Max LLM iterations reached, returning best attempt")
    fixed_recipe_data
  end

  # Aggregates violations into structured fix instructions
  # Groups violations by step number for clarity
  #
  # @param violations [Array<Hash>] Array of violation hashes
  # @return [String] Aggregated fix instructions
  def self.aggregate_fix_instructions(violations)
    # Group violations by step number if possible
    step_violations = {}
    other_violations = []

    violations.each do |violation|
      # Extract step number from message if present
      step_match = violation[:message].match(/step (\d+)/i)
      if step_match
        step_num = step_match[1].to_i
        step_violations[step_num] ||= []
        step_violations[step_num] << violation
      else
        other_violations << violation
      end
    end

    instructions = []

    # Add step-specific violations grouped by step
    step_violations.sort.each do |step_num, step_viols|
      instructions << "Step #{step_num} violations:"
      step_viols.each do |violation|
        instructions << "  - #{violation[:type]}: #{violation[:message]}"
        instructions << "    Fix: #{violation[:fix_instruction]}"
      end
    end

    # Add other violations
    other_violations.each do |violation|
      instructions << "#{violation[:type]}: #{violation[:message]}"
      instructions << "  Fix: #{violation[:fix_instruction]}"
    end

    instructions.join("\n")
  end

  # Builds a prompt for fixing violations
  #
  # @param recipe_data [Hash] Current recipe data
  # @param fix_instructions [String] Aggregated fix instructions
  # @param user_message [Message] Original user message
  # @return [String] Fix prompt
  def self.build_fix_prompt(recipe_data:, fix_instructions:, user_message:)
    <<~PROMPT
      CRITICAL: The recipe you just generated has validation violations that MUST be fixed.

      Current Recipe:
      Title: #{recipe_data['title']}
      Description: #{recipe_data['description']}
      Instructions: #{recipe_data.dig('content', 'instructions')&.join("\n") || 'None'}

      Validation Violations Found:
      #{fix_instructions}

      CRITICAL RULES FOR FIXING:
      1. Allergen warnings MUST be in the INSTRUCTION STEP where the allergen is added, NOT in the description
      2. The warning MUST start with "⚠️ WARNING:" (capitalized, not "warning" or "Warning") at the BEGINNING of the instruction step
      3. The warning MUST mention the specific allergen from the user's allergy list
      4. Use ONLY clean allergen/ingredient names - do NOT include filler words from user messages (e.g., use "sesame" not "sesame anyway")
      5. The phrase "Proceed with extreme caution" must appear EXACTLY ONCE - do NOT duplicate it
      6. You MUST fix ALL violations listed above - check each step mentioned
      7. Do NOT add warnings to steps that don't contain the allergen
      8. Do NOT remove warnings from steps that already have them correctly formatted

      Return the COMPLETE fixed recipe with ALL fields (title, description, content, shopping_list, recipe_summary_for_prompt, recipe_modified, change_magnitude, message).
      Do NOT change anything that wasn't mentioned in the violations - only fix the violations.
      
      After fixing, verify that:
      - Each step mentioned in violations now has "⚠️ WARNING:" at the beginning
      - The warning mentions the specific allergen (clean name, no filler words)
      - "Proceed with extreme caution" appears exactly once (not duplicated)
      - No warnings are in the description field (they should only be in instruction steps)
    PROMPT
  end

  # Validates the fixed recipe to check if violations are resolved
  # Re-runs all validations to ensure programmatic fixes worked
  #
  # @param recipe_data [Hash] Fixed recipe data
  # @param user_message [Message] Original user message
  # @param current_user [User] Current user
  # @return [ValidationResult] Aggregated validation result
  def self.validate_fixed_recipe(recipe_data:, user_message:, current_user:)
    # Extract data
    instructions = recipe_data.dig("content", "instructions") || []
    ingredients = recipe_data.dig("content", "ingredients") || []
    shopping_list = recipe_data["shopping_list"] || []

    # Extract requested ingredients
    requested_ingredients = extract_requested_ingredients(user_message.content)

    # Get user allergies
    user_allergies = if current_user.allergies.is_a?(Hash)
                       current_user.active_allergies
                     else
                       []
                     end

    # Get user appliances
    available_appliances = if current_user.appliances.is_a?(Hash)
                             current_user.active_appliances
                           else
                             []
                           end.map(&:downcase)

    # Calculate unavailable appliances
    unavailable_appliances = RecipesController::AVAILABLE_APPLIANCES.keys.reject { |key| available_appliances.include?(key.downcase) }

    # Re-run all validations to check if fixes worked
    # We check all validations to ensure programmatic fixes resolved the issues
    aggregated_results = RecipeValidator.validate_all(
      recipe_data: recipe_data,
      user: current_user,
      user_message: user_message,
      requested_ingredients: requested_ingredients,
      available_appliances: available_appliances,
      unavailable_appliances: unavailable_appliances,
      user_allergies: user_allergies
    )

    # Return proper ValidationResult structure
    violations = aggregated_results[:violations] || []
    Tools::BaseTool.validation_result(
      valid: violations.empty?,
      violations: violations
    )
  end

  # Extracts requested ingredients from user message (same logic as controller)
  #
  # @param message [String] User message content
  # @return [Array<String>] Extracted ingredients
  def self.extract_requested_ingredients(message)
    ingredients = []
    message_lower = message.downcase

    # Filler words that should stop ingredient extraction
    filler_stop_words = %w[anyway please though still even just only]

    # Look for "add [ingredient]" patterns
    # Stop at filler words, punctuation, or common phrase endings
    message_lower.scan(/add\s+(?:more\s+)?([a-z\s]+?)(?:\s+(?:#{filler_stop_words.join('|')})|\s+to|\s+in|$|,|\.)/) do |match|
      ingredient = match[0].strip
      # Remove any filler words that might have been captured
      ingredient = ingredient.split.reject { |word| filler_stop_words.include?(word) }.join(" ")
      ingredients << ingredient if ingredient.length > 2
    end

    # Look for "with [ingredient]" patterns
    message_lower.scan(/with\s+([a-z\s]+?)(?:\s+(?:#{filler_stop_words.join('|')})|\s+and|\s+or|$|,|\.)/) do |match|
      ingredient = match[0].strip
      # Remove any filler words that might have been captured
      ingredient = ingredient.split.reject { |word| filler_stop_words.include?(word) }.join(" ")
      ingredients << ingredient if ingredient.length > 2
    end

    ingredients.uniq
  end
end

