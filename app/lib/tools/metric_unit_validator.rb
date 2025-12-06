require_relative "base_tool"
require_relative "error_classes"

# Validates and converts recipe units to metric system
# Ensures all quantities use metric units (g, ml, pieces, etc.)
# Also validates shopping list for realistic purchase amounts
# Uses pure Ruby validation and conversion (no LLM call) for 100% reliability
#
# Validation checks:
# - Recipe ingredients use metric units (g, ml, pieces, etc.)
# - Shopping list uses metric units and realistic purchase amounts
# - Converts non-metric units (teaspoons, cups, etc.) to metric
# - Removes unrealistic small amounts from shopping list (e.g., "2g black pepper" -> "black pepper")
# - Converts "1 clove garlic" to "1 head garlic" or "1 bulb garlic"
#
# Returns structured validation result with violations and converted values
module Tools
  class MetricUnitValidator
    include BaseTool

    # Unit conversion factors (to metric)
    UNIT_CONVERSIONS = {
      # Volume conversions (to milliliters)
      "teaspoon" => 5, # ml
      "teaspoons" => 5,
      "tsp" => 5,
      "tablespoon" => 15, # ml
      "tablespoons" => 15,
      "tbsp" => 15,
      "cup" => 240, # ml
      "cups" => 240,
      "pint" => 473, # ml
      "pints" => 473,
      "quart" => 946, # ml
      "quarts" => 946,
      "gallon" => 3785, # ml
      "gallons" => 3785,
      "fl oz" => 30, # ml
      "fluid ounce" => 30,
      "fluid ounces" => 30,
      # Weight conversions (to grams)
      "ounce" => 28.35, # g
      "oz" => 28.35,
      "ounces" => 28.35,
      "pound" => 453.6, # g
      "lb" => 453.6,
      "lbs" => 453.6,
      "pounds" => 453.6
    }.freeze

    # Units that should NOT appear in shopping list (too small for realistic purchase)
    UNREALISTIC_SHOPPING_UNITS = %w[teaspoon teaspoons tsp tablespoon tablespoons tbsp pinch pinches dash dashes clove cloves slice slices leaves].freeze

    # Words that indicate processed/prepared items (should be removed or converted)
    PROCESSED_INDICATORS = %w[cooked sliced diced chopped minced grated shredded melted].freeze

    # Dry ingredients that should be measured in grams (not ml)
    # These are typically sold by weight, not volume
    DRY_INGREDIENTS = %w[
      flour salt sugar pepper paprika cumin cinnamon turmeric oregano basil thyme rosemary sage
      garlic powder onion powder baking powder baking soda cocoa powder cornstarch starch
      rice pasta noodles oats grains beans lentils chickpeas nuts seeds almonds walnuts
      breadcrumbs bread croutons crackers chips
    ].freeze

    # Liquid ingredients that should be measured in milliliters
    LIQUID_INGREDIENTS = %w[
      water milk juice oil vinegar wine beer broth stock sauce soy sauce tamari
      lemon juice lime juice orange juice apple juice
    ].freeze

    # Minimum realistic purchase amounts for shopping list (in grams or ml)
    MINIMUM_PURCHASE_AMOUNTS = {
      "pepper" => 50, # g - spices are usually sold in 50g+ containers
      "black pepper" => 50,
      "salt" => 200, # g
      "garlic" => 1, # head/bulb - not grams
      "olive oil" => 250, # ml - usually sold in 250ml+ bottles
      "oil" => 250,
      "vinegar" => 250,
      "spices" => 50 # general minimum for spice containers
    }.freeze

    # Validates and converts units in recipe
    #
    # @param ingredients [Array<String>] The recipe ingredients array
    # @param shopping_list [Array<String>] The shopping list array
    # @return [ValidationResult] Validation result with violations and converted values
    def self.validate(ingredients:, shopping_list:)
      violations = []
      ingredients = Array(ingredients) # Ensure it's an array
      shopping_list = Array(shopping_list) # Ensure it's an array

      converted_ingredients = []
      converted_shopping_list = []

      # Validate and convert ingredients
      ingredients.each do |ingredient|
        converted = convert_ingredient_to_metric(ingredient)
        if converted[:needs_conversion]
          violations << BaseTool.violation(
            type: :non_metric_unit_in_ingredients,
            message: "Ingredient '#{ingredient}' uses non-metric unit '#{converted[:original_unit]}'",
            field: :ingredients,
            fix_instruction: "Convert to metric: #{converted[:converted]}"
          )
        end
        converted_ingredients << converted[:converted]
      end

      # Validate and convert shopping list (stricter rules)
      shopping_list.each do |item|
        converted = convert_shopping_item_to_realistic(item)
        if converted[:needs_conversion] || converted[:needs_fix]
          violation_type = converted[:needs_fix] ? :unrealistic_shopping_amount : :non_metric_unit_in_shopping_list
          violations << BaseTool.violation(
            type: violation_type,
            message: "Shopping list item '#{item}' #{converted[:issue_description]}",
            field: :shopping_list,
            fix_instruction: "Fix to realistic purchase amount: #{converted[:converted]}"
          )
        end
        converted_shopping_list << converted[:converted]
      end

      # Generate fix instructions
      fix_instructions = generate_fix_instructions(violations, converted_ingredients, converted_shopping_list)

      result = BaseTool.validation_result(
        valid: violations.empty?,
        violations: violations,
        fix_instructions: fix_instructions
      )

      # Store converted data for programmatic fixes (using instance variable on result)
      result.instance_variable_set(:@converted_ingredients, converted_ingredients)
      result.instance_variable_set(:@converted_shopping_list, converted_shopping_list)

      result
    end

    private

    # Converts ingredient to metric units
    #
    # @param ingredient [String] Ingredient string (e.g., "2 cups flour")
    # @return [Hash] { needs_conversion: boolean, original_unit: string, converted: string }
    def self.convert_ingredient_to_metric(ingredient)
      # Try each known unit to find a match
      UNIT_CONVERSIONS.each do |unit_key, conversion_factor|
        # Create regex pattern for this unit (handle spaces in multi-word units)
        unit_pattern = unit_key.gsub(/\s+/, '\s+')
        pattern = /^(\d+(?:\.\d+)?)\s+#{unit_pattern}(?:\s+|$)/i
        
        if ingredient.match?(pattern)
          match = ingredient.match(/^(\d+(?:\.\d+)?)\s+#{unit_pattern}\s*(.*)/i)
          next unless match

          amount = match[1].to_f
          remaining_text = (match[2] || "").strip

          # Determine if it's volume or weight based on ingredient type
          # Check if the remaining text (ingredient name) indicates it's a liquid or dry ingredient
          ingredient_lower = remaining_text.downcase
          is_liquid = LIQUID_INGREDIENTS.any? { |liquid| ingredient_lower.include?(liquid) }
          is_dry = DRY_INGREDIENTS.any? { |dry| ingredient_lower.include?(dry) }

          # Determine conversion unit:
          # - If unit is a volume unit (cup, teaspoon, etc.) and ingredient is dry -> convert to grams
          # - If unit is a volume unit and ingredient is liquid -> convert to ml
          # - If unit is a weight unit (ounce, pound) -> convert to grams
          unit_is_volume = %w[teaspoon tsp tablespoon tbsp cup cups pint quart gallon fl oz fluid ounce fluid ounces].include?(unit_key)
          unit_is_weight = %w[ounce oz ounces pound lb lbs pounds].include?(unit_key)

          if unit_is_volume
            # Volume unit: determine by ingredient type
            converted_unit = is_liquid ? "ml" : "g"
            # For dry ingredients, we need to use density conversion
            # Common densities: flour ~0.6 g/ml, sugar ~0.85 g/ml, salt ~1.2 g/ml
            # For simplicity, use average density of 0.7 g/ml for dry ingredients
            if is_dry || (!is_liquid && !is_dry)
              # Dry ingredient or unknown: use density conversion
              density = 0.7 # g/ml average for dry ingredients
              converted_amount = (amount * conversion_factor * density).round(1)
            else
              # Liquid: direct volume conversion
              converted_amount = (amount * conversion_factor).round(1)
            end
          elsif unit_is_weight
            # Weight unit: always convert to grams
            converted_unit = "g"
            converted_amount = (amount * conversion_factor).round(1)
          else
            # Unknown unit type - shouldn't happen, but default to ml
            converted_unit = "ml"
            converted_amount = (amount * conversion_factor).round(1)
          end

          # Remove trailing zeros
          converted_amount = converted_amount.to_i if converted_amount == converted_amount.to_i

          # Reconstruct ingredient string
          converted = if remaining_text.empty?
                        "#{converted_amount}#{converted_unit}"
                      else
                        "#{converted_amount}#{converted_unit} #{remaining_text}"
                      end

          return {
            needs_conversion: true,
            original_unit: unit_key,
            converted: converted
          }
        end
      end

      # No conversion needed
      { needs_conversion: false, converted: ingredient }
    end

    # Converts shopping list item to realistic purchase amount
    #
    # @param item [String] Shopping list item (e.g., "2g black pepper")
    # @return [Hash] { needs_conversion: boolean, needs_fix: boolean, issue_description: string, converted: string }
    def self.convert_shopping_item_to_realistic(item)
      # Check for processed/prepared items (cooked, sliced, etc.) - remove these words
      item_lower = item.downcase
      has_processed = PROCESSED_INDICATORS.any? { |indicator| item_lower.include?(indicator) }
      
      if has_processed
        # Extract amount and unit first (if present) - include all possible units
        amount_match = item.match(/^(\d+(?:\.\d+)?)\s*(g|ml|pieces?|heads?|bulbs?|loaves?|rolls?|teaspoons?|tsp|tablespoons?|tbsp|cloves?|slices?|leaves?)\s+(.+)/i)
        
        if amount_match
          # Has amount - clean the item name part
          amount_str = amount_match[1]
          unit = amount_match[2]
          item_name = amount_match[3]
          
          # Remove processed indicators from item name
          cleaned_name = item_name.dup
          PROCESSED_INDICATORS.each do |indicator|
            cleaned_name = cleaned_name.gsub(/\s+#{indicator}\s+/i, " ")
            cleaned_name = cleaned_name.gsub(/\s+#{indicator}$/i, "")
            cleaned_name = cleaned_name.gsub(/^#{indicator}\s+/i, "")
          end
          cleaned_name = cleaned_name.gsub(/\s+/, " ").strip
          
          # Check if unit is unrealistic (teaspoon, tablespoon, etc.)
          if UNREALISTIC_SHOPPING_UNITS.include?(unit)
            # Unit is unrealistic - convert to realistic purchase
            converted = make_realistic_purchase(cleaned_name)
          # Check if this is meat that should have a realistic package size
          elsif cleaned_name.include?("turkey") || cleaned_name.include?("chicken") || cleaned_name.include?("ham") || cleaned_name.include?("beef") || cleaned_name.include?("pork")
            # Remove "slices" and other processing words from meat name
            meat_name = cleaned_name.dup
            meat_name = meat_name.gsub(/\s*slices?\s*/i, " ")
            meat_name = meat_name.gsub(/\s+/, " ").strip
            # For meat, use realistic package size (200g typical deli package)
            converted = "200g #{meat_name}"
          elsif is_produce?(cleaned_name) && amount_str.to_f < 100
            # Small amount of produce - convert to whole item
            converted = make_realistic_produce_purchase(cleaned_name)
          else
            # Keep the amount but use cleaned name
            converted = "#{amount_str}#{unit} #{cleaned_name}"
          end
          
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "contains processed/prepared indicator (cooked, sliced, etc.)",
            converted: converted
          }
        else
          # No amount - clean and add realistic amount if needed
          cleaned_item = item.dup
          PROCESSED_INDICATORS.each do |indicator|
            cleaned_item = cleaned_item.gsub(/\s+#{indicator}\s+/i, " ")
            cleaned_item = cleaned_item.gsub(/\s+#{indicator}$/i, "")
            cleaned_item = cleaned_item.gsub(/^#{indicator}\s+/i, "")
          end
          cleaned_item = cleaned_item.gsub(/\s+/, " ").strip
          
          # Check if it's produce or meat
          if is_produce?(cleaned_item)
            converted = make_realistic_produce_purchase(cleaned_item)
          elsif cleaned_item.include?("turkey") || cleaned_item.include?("chicken") || cleaned_item.include?("ham")
            # Meat - return with realistic package size
            meat_name = cleaned_item.gsub(/\s*(slices?|breast|thigh|drumstick)\s*/i, " ").strip
            converted = "200g #{meat_name}"
          else
            converted = cleaned_item
          end
          
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "contains processed/prepared indicator (cooked, sliced, etc.)",
            converted: converted
          }
        end
      end

      # Extract number and unit from item string
      # Pattern: amount (number) + unit (g/ml/pieces/etc) + item name
      match = item.match(/^(\d+(?:\.\d+)?)\s*(g|ml|pieces?|heads?|bulbs?|cloves?|slices?|leaves?|teaspoons?|tsp|tablespoons?|tbsp|pinches?|dashes?)\s+(.+)/i)
      
      if match
        amount_str = match[1]
        unit = match[2].strip.downcase
        item_name = match[3].strip.downcase

        # Check for unrealistic units in shopping list
        if UNREALISTIC_SHOPPING_UNITS.include?(unit)
          # Remove unrealistic unit, make it a realistic purchase
          converted = make_realistic_purchase(item_name)
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "uses unrealistic unit '#{unit}' for shopping",
            converted: converted
          }
        end

        # Extract numeric amount
        amount = amount_str.to_f

        # Check for unrealistic small amounts
        # For spices, condiments, baking items, and sweeteners, even small amounts in grams/ml are unrealistic
        if amount && (unit == "g" || unit == "ml")
          if is_spice_or_condiment?(item_name)
            # For these items, any small amount (< 50g or < 100ml) should be converted to realistic container size
            if (unit == "g" && amount < 50) || (unit == "ml" && amount < 100)
              converted = make_realistic_purchase(item_name)
              return {
                needs_conversion: true,
                needs_fix: true,
                issue_description: "has unrealistic small amount (#{amount_str}) for shopping",
                converted: converted
              }
            end
          end
        end

        # Check for unrealistic units (teaspoons, tablespoons) in shopping list
        if unit == "teaspoon" || unit == "tsp" || unit == "tablespoon" || unit == "tbsp"
          converted = make_realistic_purchase(item_name)
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "uses unrealistic unit '#{unit}' for shopping",
            converted: converted
          }
        end

        # Check for "1 clove garlic" -> should be "1 head garlic" or "1 bulb garlic"
        if unit == "clove" && amount == 1 && item_name.include?("garlic")
          converted = "1 head garlic"
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "uses 'clove' which is not a realistic purchase unit",
            converted: converted
          }
        end

        # Check for bread slices -> should be "1 loaf" or just "bread"
        if (unit == "slice" || unit == "slices") && item_name.include?("bread")
          converted = make_realistic_purchase(item_name)
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "uses 'slice' which is not a realistic purchase unit",
            converted: converted
          }
        end

        # Check for lettuce leaves -> should be "1 head lettuce"
        if (unit == "leaf" || unit == "leaves") && item_name.include?("lettuce")
          converted = "1 head lettuce"
          return {
            needs_conversion: true,
            needs_fix: true,
            issue_description: "uses 'leaves' which is not a realistic purchase unit",
            converted: converted
          }
        end

        # Check for small amounts of produce (cucumber, tomato, etc.) - convert to whole items
        if amount && amount < 100 && (unit == "g" || unit == "ml")
          if is_produce?(item_name)
            converted = make_realistic_produce_purchase(item_name)
            return {
              needs_conversion: true,
              needs_fix: true,
              issue_description: "has unrealistic small amount (#{amount_str}) for produce",
              converted: converted
            }
          end
        end

        # Convert non-metric units to metric
        if unit && UNIT_CONVERSIONS[unit]
          conversion_factor = UNIT_CONVERSIONS[unit]
          is_volume = %w[teaspoon tsp tablespoon tbsp cup cups pint quart gallon fl oz fluid ounce fluid ounces].include?(unit)
          converted_unit = is_volume ? "ml" : "g"
          converted_amount = (amount * conversion_factor).round(1)
          converted_amount = converted_amount.to_i if converted_amount == converted_amount.to_i

          # Check if converted amount is still too small for realistic purchase
          if converted_amount < 10 && is_spice_or_condiment?(item_name)
            converted = make_realistic_purchase(item_name)
            return {
              needs_conversion: true,
              needs_fix: true,
              issue_description: "converted amount (#{converted_amount}#{converted_unit}) is too small for realistic purchase",
              converted: converted
            }
          end

          converted = "#{converted_amount}#{converted_unit} #{item_name}"
          return {
            needs_conversion: true,
            needs_fix: false,
            issue_description: "uses non-metric unit",
            converted: converted
          }
        end
      end

      # No conversion needed
      { needs_conversion: false, needs_fix: false, converted: item }
    end

    # Checks if item is a spice or condiment that should be bought in larger quantities
    #
    # @param item_name [String] Item name
    # @return [Boolean] True if it's a spice or condiment
    def self.is_spice_or_condiment?(item_name)
      spices = %w[pepper salt paprika cumin cinnamon turmeric oregano basil thyme rosemary sage garlic powder onion powder]
      condiments = %w[oil vinegar soy sauce mustard ketchup mayonnaise]
      baking_items = %w[baking powder baking soda vanilla extract vanilla]
      sweeteners = %w[maple syrup honey syrup]
      
      spices.any? { |spice| item_name.include?(spice) } ||
        condiments.any? { |condiment| item_name.include?(condiment) } ||
        baking_items.any? { |item| item_name.include?(item) } ||
        sweeteners.any? { |sweetener| item_name.include?(sweetener) }
    end

    # Checks if item is fresh produce that should be bought whole
    #
    # @param item_name [String] Item name
    # @return [Boolean] True if it's produce
    def self.is_produce?(item_name)
      produce = %w[cucumber tomato lettuce pepper bell pepper onion garlic carrot celery broccoli cauliflower
                   zucchini eggplant potato sweet potato avocado lemon lime orange apple banana]
      
      produce.any? { |item| item_name.include?(item) }
    end

    # Makes a realistic purchase amount for fresh produce
    #
    # @param item_name [String] Item name
    # @return [String] Realistic purchase amount
    def self.make_realistic_produce_purchase(item_name)
      # Remove any processed indicators that might still be there
      cleaned_name = item_name.dup
      PROCESSED_INDICATORS.each do |indicator|
        cleaned_name = cleaned_name.gsub(/\s+#{indicator}\s+/i, " ")
        cleaned_name = cleaned_name.gsub(/\s+#{indicator}$/i, "")
        cleaned_name = cleaned_name.gsub(/^#{indicator}\s+/i, "")
      end
      cleaned_name = cleaned_name.gsub(/\s+/, " ").strip

      # Remove "leaves" for lettuce
      cleaned_name = cleaned_name.gsub(/\s+leaves?\s*/i, " ").strip

      # For lettuce, return head
      if cleaned_name.include?("lettuce")
        return "1 head lettuce"
      end

      # For most produce, return "1 [item]" or "2 [item]" depending on typical purchase
      # Extract the main item name (remove descriptors like "fresh", "whole", etc.)
      main_item = cleaned_name.split.reject { |word| %w[fresh whole large small medium].include?(word.downcase) }.join(" ")

      # For items typically sold individually
      if %w[cucumber tomato avocado lemon lime orange apple banana pepper bell pepper].any? { |item| main_item.include?(item) }
        return "1 #{main_item}"
      end

      # For items typically sold in bunches or packs
      if %w[lettuce celery broccoli].any? { |item| main_item.include?(item) }
        return "1 #{main_item}"
      end

      # Default: return item name
      "1 #{main_item}"
    end

    # Makes a realistic purchase amount for spices/condiments
    #
    # @param item_name [String] Item name
    # @return [String] Realistic purchase amount
    def self.make_realistic_purchase(item_name)
      # Handle "or" alternatives - take the first option
      item_name = item_name.split(" or ").first.strip if item_name.include?(" or ")

      # For spices, just return the name (they're usually sold in standard containers)
      if item_name.include?("pepper") || item_name.include?("salt") || item_name.include?("spice")
        return item_name.split.last(2).join(" ") # Return last 2 words (e.g., "black pepper")
      end

      # For baking powder, baking soda - return container size
      if item_name.include?("baking powder") || item_name.include?("baking soda")
        return "100g #{item_name}"
      end

      # For vanilla extract - return bottle size
      if item_name.include?("vanilla extract") || item_name.include?("vanilla")
        return "50ml vanilla extract"
      end

      # For maple syrup, honey - return bottle size
      if item_name.include?("maple syrup")
        return "250ml maple syrup"
      end
      if item_name.include?("honey")
        return "250g honey"
      end

      # For oils/vinegars, suggest a realistic bottle size
      if item_name.include?("oil") || item_name.include?("vinegar")
        # Remove "melted" and other processed indicators, and handle "or" alternatives
        oil_name = item_name.split(" or ").first.strip # Take first option if "or" present
        PROCESSED_INDICATORS.each do |indicator|
          oil_name = oil_name.gsub(/\s+#{indicator}\s+/i, " ")
          oil_name = oil_name.gsub(/\s+#{indicator}$/i, "")
          oil_name = oil_name.gsub(/^#{indicator}\s+/i, "")
        end
        oil_name = oil_name.gsub(/\s+/, " ").strip
        return "250ml #{oil_name}"
      end

      # For garlic, return head/bulb
      if item_name.include?("garlic")
        return "1 head garlic"
      end

      # For bread, return "1 loaf" or just the bread name
      if item_name.include?("bread")
        # Extract bread type (e.g., "whole wheat bread" -> "1 loaf whole wheat bread")
        bread_type = item_name.gsub(/\s*slices?\s*/i, "").strip
        return "1 loaf #{bread_type}"
      end

      # For turkey/meat slices, return whole item
      if item_name.include?("turkey") || item_name.include?("chicken") || item_name.include?("ham") || item_name.include?("beef") || item_name.include?("pork")
        # Remove "slices", "cooked", and other processed indicators
        meat_type = item_name.dup
        PROCESSED_INDICATORS.each do |indicator|
          meat_type = meat_type.gsub(/\s+#{indicator}\s+/i, " ")
          meat_type = meat_type.gsub(/\s+#{indicator}$/i, "")
        end
        meat_type = meat_type.gsub(/\s+/, " ").strip
        return "200g #{meat_type}" # Typical deli meat package size
      end

      # Default: return item name without amount
      item_name
    end

    # Generates fix instructions for violations
    #
    # @param violations [Array<Hash>] Violations
    # @param converted_ingredients [Array<String>] Converted ingredients
    # @param converted_shopping_list [Array<String>] Converted shopping list
    # @return [String] Fix instructions
    def self.generate_fix_instructions(violations, converted_ingredients, converted_shopping_list)
      return "No unit violations found." if violations.empty?

      instructions = []
      instructions << "CRITICAL: The recipe uses non-metric units or unrealistic shopping amounts."
      instructions << ""
      instructions << "Converted Ingredients:"
      converted_ingredients.each do |ingredient|
        instructions << "  - #{ingredient}"
      end
      instructions << ""
      instructions << "Converted Shopping List (realistic purchase amounts):"
      converted_shopping_list.each do |item|
        instructions << "  - #{item}"
      end
      instructions << ""
      instructions << "Fix instructions:"
      instructions << "1. Replace all non-metric units with metric equivalents (g, ml, pieces)"
      instructions << "2. Ensure shopping list uses realistic purchase amounts (no teaspoons, pinches, or tiny amounts)"
      instructions << "3. Convert '1 clove garlic' to '1 head garlic' in shopping list"
      instructions << "4. For spices, use realistic container sizes or just the spice name"

      instructions.join("\n")
    end
  end
end

