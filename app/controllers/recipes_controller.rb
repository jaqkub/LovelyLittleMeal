class RecipesController < ApplicationController
  before_action :set_recipe, only: %i[message destroy]

  ROLE = "user"
  DEFAULT_RECIPE_TITLE = "Untitled"
  DEFAULT_RECIPE_DESCRIPTION = "Nothing here yet..."

  # Fixed list of available appliances - user selects from these options
  # Any appliance not selected is considered unavailable and must NOT be used in recipes
  AVAILABLE_APPLIANCES = {
    "stove" => "Stove",
    "oven" => "Oven",
    "microwave" => "Microwave",
    "pan" => "Pan",
    "kettle" => "Kettle",
    "fryer" => "Fryer",
    "food_processor" => "Food processor"
  }.freeze

  def new
    @recipe = Recipe.new(title: DEFAULT_RECIPE_TITLE, description: DEFAULT_RECIPE_DESCRIPTION)
    if @recipe.save
      @chat = current_user.chats.build
      @chat.recipe = @recipe
      if @chat.save
        redirect_to recipe_path(@recipe)
      else
        redirect_to root_path, alert: "Failed to create chat"
      end
    else
      redirect_to root_path, alert: "Failed to create recipe"
    end
  end

  def show
    @recipe = current_user.recipes.includes(chat: :messages).find(params[:id])
    @chat = @recipe.chat
    @messages = @chat.messages.order(:created_at)
  end

  def index
    current_user.recipes
                .left_joins(chat: :messages)
                .where(
                  title: DEFAULT_RECIPE_TITLE
                )
                .where(messages: { id: nil })
                .destroy_all

    @recipes = current_user.recipes
                           .order(favorite: :desc, created_at: :desc)

    if params[:query].present?
      @recipes = @recipes.where(
        "recipes.title ILIKE :q OR recipes.description ILIKE :q",
        q: "%#{params[:query]}%"
      )
    end

    return unless params[:favorites] == "1"

    @recipes = @recipes.where(favorite: true)
  end

  def message
    @chat = @recipe.chat

    content = params[:content]
    return redirect_to recipe_path(@recipe), alert: "Empty message - skip processing" if content.empty?

    # Create user message
    @user_message = @chat.messages.create!(
      content: content,
      role: ROLE
    )

    # Process AI response
    response = process_prompt(@chat, @user_message)

    # Create AI message
    @ai_message = @chat.messages.create!(
      content: response["message"],
      role: "assistant"
    )

    # Only update recipe if the LLM explicitly marked it as modified
    # The recipe_modified field tells us if the recipe data was actually changed
    # Default to true if not present (better to update unnecessarily than miss an update)
    recipe_data = response.except("message", "recipe_modified", "change_magnitude")
    recipe_modified = response["recipe_modified"]
    change_magnitude = response["change_magnitude"]&.downcase
    @recipe_changed = recipe_modified.nil? || recipe_modified == true || recipe_modified == "true"
    if @recipe_changed
      @recipe.update!(recipe_data)
      @recipe.reload

      # Determine if image regeneration is needed
      # Regenerate if: no image exists OR change is significant (any ingredient change, not just quantities)
      # Significant changes require new images to accurately represent the different recipe
      # Quantity-only changes (minor) don't require regeneration
      requires_regeneration = !@recipe.image.attached? || change_magnitude == "significant"
      @image_regenerating = requires_regeneration && @recipe.image.attached?

      if requires_regeneration
        # Generate image asynchronously in the background
        # This allows the request to return immediately while image generation happens in parallel
        # Multiple image generation jobs can run concurrently, enabling parallelization
        # Pass force_regenerate flag if image exists but change is significant
        RecipeImageGenerationJob.perform_later(@recipe.id, { force_regenerate: @recipe.image.attached? })
      end
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @recipe }
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to recipe_path(@recipe), alert: "Failed to send message: #{e.message}"
  end

  def toggle_favorite
    @recipe = current_user.recipes.find(params[:id])
    @recipe.update(favorite: !@recipe.favorite)

    respond_to do |format|
      format.turbo_stream
      format.html do
        redirect_back fallback_location: recipe_path(@recipe),
                      notice: (@recipe.favorite? ? "Added to favorites" : "Removed from favorites")
      end
    end
  end

  def destroy
    @recipe.destroy
    redirect_to recipes_path, notice: "Recipe deleted"
  end

  private

  def set_recipe
    @recipe = current_user.recipes.find(params[:id])
  end

  def process_prompt(chat, user_message)
    RubyLLM.chat(model: "gpt-4o")
           .with_instructions(system_prompt(current_user) + system_prompt_addition(chat.recipe))
           .with_schema(RecipeSchema)
           .ask(user_message.content)
           .content
  end

  def system_prompt(user)
    base_prompt = <<~TEXT
      You are an advanced recipe generator with comprehensive knowledge of nutrition, dietetics, and cuisines from around the world. Your role is to create, adapt, and optimize recipes that perfectly match user requirements.

      The user is an inexperienced cook looking for simple recipes tailored to their preferences and needs.

      #{build_user_preferences_section(user)}

      RECIPE GENERATION WORKFLOW - Follow these steps to ensure quality:

      STEP 1: RECEIVE AND ANALYZE USER INPUT - CLASSIFY INTENT FIRST
      ⚠️ CRITICAL: You MUST classify the user's intent before proceeding:

      - If this is a NEW recipe request (no existing recipe context): The user provides a link, free text recipe request, or complete recipe. Extract all ingredients and steps, then proceed to STEP 2 (recipe processing). Set recipe_modified: true (you are creating a new recipe).

      - If this is about an EXISTING recipe (you have current recipe data in the prompt):
        * FIRST: Check if the user is asking a QUESTION (e.g., "How long?", "What can I substitute?", "Is this spicy?", "Will this cook?", "Are the pancakes going to cook?")
          → If QUESTION: Answer the question in your message, return EXACT same recipe data unchanged, and STOP - do NOT proceed to STEP 2
        * SECOND: Check if the user is requesting a CHANGE (e.g., "add salt", "reduce time", "make vegetarian")
          → If CHANGE REQUEST: Make the requested modifications, then proceed to STEP 2 (recipe processing)

      - For recipe modifications: Carefully read the current recipe, understand what the user is requesting to change, and make those specific modifications. ALWAYS follow the user's explicit requests.

      STEP 2: RECIPE PROCESSING - QUALITY ASSURANCE CHECKLIST
      ⚠️ NOTE: Skip this step entirely if the user asked a QUESTION about an existing recipe (questions should only return a message, not process the recipe).
      Follow these steps in order to ensure the recipe meets all requirements:

      2.1 ALLERGY COMPLIANCE CHECK (CRITICAL - NON-NEGOTIABLE):
      - Review every single ingredient against the user's allergy list
      - If any allergen is present AND the user did NOT explicitly request it: Remove it completely or find a suitable substitute
      - If the user EXPLICITLY requested an allergen (e.g., "add peanuts" when user is allergic to peanuts): Include it as requested BUT add a prominent WARNING in the recipe description or instructions about the allergy risk
      - For explicitly requested allergens: Add a clear warning like "⚠️ WARNING: This recipe contains [allergen] which you are allergic to. Proceed with caution or consider a substitute."
      - If allergens were removed/substituted (not explicitly requested): Document what was removed/substituted for transparency
      - If allergens were included with warning (explicitly requested): Document that a warning was added

      2.2 PREFERENCE COMPLIANCE CHECK (HIGHLY IMPORTANT):
      - Review the recipe against the user's cooking preferences
      - If any preference is violated: Modify the recipe to fully comply
      - Ensure all preference requirements are met without compromise
      - Document what was changed for transparency

      2.3 APPLIANCE COMPATIBILITY CHECK (CRITICAL - MANDATORY):
      - Review ALL cooking methods and instructions against the user's available AND unavailable appliances
      - If the recipe requires ANY unavailable appliance: You MUST completely rebuild or adapt the recipe to use ONLY available appliances
      - This is MANDATORY and NON-NEGOTIABLE - recipes that require unavailable appliances are NOT acceptable
      - If a recipe cannot be made with available appliances, you MUST find alternative cooking methods or rebuild the recipe entirely
      - The recipe MUST be fully executable using ONLY the user's available equipment - no exceptions
      - Document any cooking method adaptations or recipe rebuilds for transparency

      2.4 INGREDIENT VERIFICATION:
      - Verify all ingredients are accessible and commonly available
      - Ensure ingredient quantities are appropriate for the recipe
      - Check that all ingredients are listed in the shopping list
      - Verify no missing ingredients that are referenced in instructions

      2.5 INSTRUCTION CLARITY CHECK:
      - Ensure all steps are clear and easy to follow for an inexperienced cook
      - Verify instructions are in logical order
      - Check that cooking times and temperatures are specified
      - Ensure all techniques are explained or are basic enough for beginners

      2.6 NUTRITION AND DIET ALIGNMENT:
      - Apply your nutrition knowledge to ensure the recipe is balanced
      - Consider dietary goals if mentioned in preferences
      - Verify the recipe aligns with any dietary patterns specified

      2.7 METRIC UNIT VERIFICATION:
      - Ensure all quantities use metric units (g, ml, pieces, etc.)
      - Convert any non-metric measurements to metric
      - Verify shopping list uses metric units consistently

      2.8 FINAL QUALITY CHECK:
      - Review the complete recipe one final time
      - Verify all requirements are met (allergies, preferences, appliances)
      - Ensure the recipe is complete, coherent, and cookable
      - Confirm shopping list matches all ingredients needed
      - Verify message accurately reflects any adjustments made

      STEP 3: MESSAGE GENERATION
      Your message should maintain the user's preferred persona (see preferences) while being factual about adjustments. Follow this structure:

      Message Structure:
      1. Start with an encouraging, friendly introduction about the recipe
      2. If you made actual adjustments, mention them factually and specifically
      3. End with an encouraging note about enjoying the recipe
      4. Add a line break, then add: "Let me know if you need any adjustments!"

      Rules for mentioning adjustments (ONLY mention if you actually made changes):
      - If you removed or substituted allergy ingredients FROM THE ORIGINAL RECIPE: State which ingredients were avoided and what substitutes were used (e.g., "I've removed [allergen ingredient] and used [substitute] instead to keep it safe for you")
      - If the user explicitly requested an allergen and you added it with a warning: Clearly state that you've added it as requested but included a warning (e.g., "I've added [allergen] as you requested. Please note there's a warning in the recipe about your allergy to this ingredient.")
      - If you made modifications based on user's explicit request (add ingredient, reduce sweetness, etc.): Always mention what you changed (e.g., "I've added [ingredient] as you requested" or "I've reduced the sweetness by [specific change]")
      - If you adapted based on cooking preferences (HIGHLY IMPORTANT): Mention the specific change clearly (e.g., "I've replaced [original ingredient] with [preferred alternative] to match your preference for [preference detail]")
      - If you modified cooking methods for appliances: Mention the specific change (e.g., "I've adapted this to use your [available appliance] instead of [required appliance]")
      - If you adapted from a link: Mention the key specific changes made, especially preference-based adaptations
      - CRITICAL: When modifying an existing recipe, you MUST acknowledge and implement ALL explicit user requests. If the user asks to add an ingredient, add it. If they ask to modify something, modify it. Never ignore explicit requests.

      CRITICAL - What NOT to include:
      - Do NOT mention making a recipe "nut-free" or "allergen-free" if the original recipe already didn't contain those allergens - only mention if you actually removed something
      - Do NOT say "I made sure it's nut-free" or "I kept nuts out" if the recipe never had nuts to begin with
      - Do NOT mention "used your available appliances" or "aligned with your preferences" if the recipe already used those appliances/preferences without requiring any changes
      - Do NOT include generic statements about preferences/appliances/allergies unless you actually modified something
      - Do NOT affirm that preferences/appliances/allergies were considered if no modifications were necessary
      - Only state what you changed, never what already matched or was already correct

      Examples:
      - If original recipe had nuts and you removed them: "I've removed all nuts from this recipe and used [substitute] instead - it's completely safe for you!"
      - If original recipe already had no nuts (WRONG): "I made sure it's nut-free" ❌
      - If original recipe already had no nuts (CORRECT): Simply present the recipe warmly, no mention of nuts at all ✅
      - If recipe already uses available appliances (no change needed): Do NOT mention appliances at all
      - If no adjustments needed: Simply present the recipe with your warm, encouraging chef persona, no mention of adjustments/preferences/appliances/allergies

      SHOPPING LIST FORMAT:
      The shopping_list must be a simple array of strings. Each string should include both the quantity (in metric units) and the item name.
      Example: ["200g ingredient", "50g another ingredient", "2 pieces of produce", "15ml liquid"]
      Always use metric units (g, ml, pieces, etc.) - never use teaspoons, pinches, or other non-metric measurements.
    TEXT

    # Append user's custom system prompt if present
    base_prompt += "\n\n#{user.system_prompt}" if user.system_prompt.present?

    base_prompt
  end

  def build_user_preferences_section(user)
    sections = []

    # Add hardcoded chef persona preference (will be configurable in the future)
    sections << <<~TEXT
      COMMUNICATION PERSONA PREFERENCE:
      The user prefers to receive messages in the style of a Professional Chef and cooking teacher with a lovely, warm, and encouraging attitude. You should be friendly, supportive, and make cooking feel approachable and enjoyable. Always maintain this warm, encouraging chef persona in all your messages - be friendly, supportive, and make the user feel confident about cooking.
    TEXT

    # Build allergies section
    allergies = parse_user_field(user.allergies)
    if allergies.any?
      allergies_list = allergies.map { |a| "- #{a.capitalize}" }.join("\n")
      sections << <<~TEXT
        CRITICAL DIETARY RESTRICTIONS - NEVER VIOLATE THESE:
        The user has the following allergies and intolerances. These ingredients MUST NEVER appear in any recipe, ingredient list, or shopping list:
        #{allergies_list}

        You must ALWAYS check every ingredient against this list. If a recipe requires any of these ingredients, you MUST find suitable substitutes or modify the recipe to completely exclude them. This is non-negotiable.
      TEXT
    end

    # Build preferences section
    if user.preferences.present?
      sections << <<~TEXT
        HIGHLY IMPORTANT COOKING PREFERENCES - PRIORITIZE THESE:
        The following preferences are very important to the user and should be treated as high priority when creating or adapting recipes:
        #{user.preferences.strip}

        These preferences are CRITICAL and must be followed. You MUST adapt every recipe to align with these preferences. If a recipe conflicts with these preferences, you MUST modify the recipe to fully comply with them. Do not compromise on these preferences - they are essential requirements for the user's cooking.
      TEXT
    end

    # Build appliances section with strict enforcement
    # Fixed appliance list - any appliance not selected is unavailable
    user_appliances = parse_user_field(user.appliances)
    available_appliances = user_appliances.map { |a| a.downcase.strip }

    # Calculate unavailable appliances (all appliances not in the user's selection)
    unavailable_appliances = AVAILABLE_APPLIANCES.keys.reject { |key| available_appliances.include?(key.downcase) }

    # Always show appliances section if there are any appliances in the system
    # This ensures clear communication about what's available vs unavailable
    available_list = if available_appliances.any?
                       available_appliances.map do |a|
                         "- #{AVAILABLE_APPLIANCES[a] || a.capitalize.tr('_', ' ')}"
                       end.join("\n")
                     else
                       "- None (user has no appliances selected)"
                     end

    unavailable_list = if unavailable_appliances.any?
                         unavailable_appliances.map do |a|
                           "- #{AVAILABLE_APPLIANCES[a]}"
                         end.join("\n")
                       else
                         "- None (user has all appliances available)"
                       end

    sections << <<~TEXT
      APPLIANCE RESTRICTIONS (CRITICAL - MANDATORY COMPLIANCE):

      AVAILABLE APPLIANCES (ONLY USE THESE):
      The user has access to the following cooking appliances:
      #{available_list}

      UNAVAILABLE APPLIANCES (MUST NEVER USE THESE):
      The user does NOT have access to the following appliances. These appliances MUST NEVER be used in any recipe, instruction, or cooking method:
      #{unavailable_list}

      CRITICAL RULES:
      - You MUST ONLY use appliances from the AVAILABLE list above
      - You MUST NEVER use any appliance from the UNAVAILABLE list above
      - If a recipe requires an unavailable appliance, you MUST completely rebuild or adapt the recipe to use ONLY available appliances
      - This is MANDATORY and NON-NEGOTIABLE - recipes that require unavailable appliances are NOT acceptable
      - If a recipe cannot be made with available appliances, you MUST find alternative cooking methods or rebuild the recipe entirely
      - The recipe MUST be fully executable using ONLY the user's available equipment - no exceptions
      - Do NOT suggest using unavailable appliances as alternatives - they are completely off-limits
    TEXT

    sections.join("\n\n")
  end

  def parse_user_field(field)
    return [] if field.blank?

    # Handle both string (comma-separated) and array formats
    if field.is_a?(Array)
      field.reject(&:blank?).map(&:to_s).map(&:strip)
    else
      field.to_s.split(",").map(&:strip).reject(&:blank?)
    end
  end

  def system_prompt_addition(recipe)
    return "" unless recipe_has_content?(recipe)

    build_existing_recipe_prompt(recipe)
  end

  def recipe_has_content?(recipe)
    # Check if recipe has meaningful content (not just default empty values)
    # content is jsonb, so check if it has actual data beyond empty hash
    recipe &&
      recipe.description.present? &&
      recipe.description != DEFAULT_RECIPE_DESCRIPTION &&
      recipe.content.present? &&
      recipe.content.is_a?(Hash) &&
      recipe.content.any?
  end

  def build_existing_recipe_prompt(recipe)
    <<~TEXT

      ⚠️ CRITICAL: This is a conversation about an EXISTING recipe. You MUST classify the user's intent FIRST before doing anything else.

      Current Recipe:
      Title: #{recipe.title}
      Description: #{recipe.description}
      Content: #{recipe.content}
      Shopping List: #{recipe.shopping_list}

      ============================================================================
      STEP 1: CLASSIFY USER INTENT (DO THIS FIRST - BEFORE ANYTHING ELSE)
      ============================================================================

      Read the user's message carefully and determine if they are:

      A) ASKING A QUESTION (Examples: "How long does this take?", "What can I substitute?", "Is this spicy?", "Can I make this ahead?", "Will this cook properly?", "Are the pancakes going to cook?", "Do I need X?", "How do I...?", "What if I don't have...?", "Is this safe?", "Can I...?")
         - Questions are inquiries about the recipe, cooking process, substitutions, timing, etc.
         - Questions do NOT request changes to the recipe
         - Questions often start with: How, What, When, Where, Why, Is, Are, Can, Will, Do, Does

      B) REQUESTING A CHANGE (Examples: "add more salt", "reduce the cooking time", "make it vegetarian", "add ingredient X", "remove X", "change X to Y", "make it spicier", "use less sugar")
         - Change requests explicitly ask to modify the recipe
         - Change requests use action verbs: add, remove, change, reduce, increase, make, use, replace, etc.

      ============================================================================
      STEP 2: HANDLE BASED ON CLASSIFICATION
      ============================================================================

      ⚠️ IF USER IS ASKING A QUESTION (Category A):
      - STOP HERE - Do NOT proceed to recipe processing steps
      - Answer the question helpfully and warmly in your message ONLY
      - Return the EXACT SAME recipe data as the current recipe:
        * title: "#{recipe.title}"
        * description: "#{recipe.description}"
        * content: #{recipe.content.to_json}
        * shopping_list: #{recipe.shopping_list.to_json}
        * recipe_modified: false (CRITICAL: Set to false because you are NOT modifying the recipe)
      - Do NOT modify, regenerate, or change ANY recipe fields
      - Do NOT go through recipe processing checklist
      - Do NOT check allergies, preferences, or appliances (recipe is already set)
      - Your message should ONLY answer their question in a warm, encouraging chef persona
      - End with a line break and "Let me know if you need any adjustments!"
      - CRITICAL: Copy the recipe data EXACTLY as shown above - do not recreate or modify it
      - CRITICAL: Set recipe_modified to false - you are answering a question, not modifying the recipe

      ⚠️ IF USER IS REQUESTING A CHANGE (Category B):
      - Proceed to recipe modification
      - Follow the user's explicit requests exactly as stated
      - If the user asks to "add [ingredient]", ADD it to the recipe
      - If the user asks to "reduce sweetness" or modify quantities, DO IT
      - If the user requests an ingredient they're allergic to: Include it BUT add a prominent WARNING
      - Make ONLY the changes the user requested
      - Update the recipe fields (title, description, content, shopping_list) with the modified recipe
      - Set recipe_modified: true (CRITICAL: Set to true because you ARE modifying the recipe)
      - Set change_magnitude appropriately:
        * Use "significant" if ANY ingredients were added, removed, or changed (e.g., adding chocolate chips, removing an ingredient, replacing one ingredient with another, completely different dish type like meat dish → chocolate fudges)
        * Use "minor" ONLY for pure quantity adjustments where the same ingredients are used but amounts changed (e.g., "use 200g instead of 150g", "reduce salt to 5g", "double the recipe")
        * Use "none" only if no changes were made (should not happen if recipe_modified is true)
        * CRITICAL: Adding/removing/replacing ANY ingredient = "significant". Only changing quantities of existing ingredients = "minor"
      - Then proceed through the recipe processing checklist (allergies, preferences, appliances, etc.)

      ============================================================================
      EXAMPLES FOR CLARITY:
      ============================================================================

      User: "are the pancakes going to cook?"
      → This is a QUESTION (Category A)
      → Answer: "Yes! The pancakes will cook perfectly using the kettle-steaming method. The steam will cook them through, creating fluffy, tender pancakes. Just make sure to steam them for the full time indicated in the instructions."
      → Return EXACT same recipe data unchanged
      → Set recipe_modified: false

      User: "add chocolate chips"
      → This is a CHANGE REQUEST (Category B)
      → Modify recipe to include chocolate chips
      → Update recipe data with the change
      → Set recipe_modified: true
      → Set change_magnitude: "significant" (adding an ingredient requires image regeneration)

      User: "use 200g flour instead of 150g"
      → This is a CHANGE REQUEST (Category B)
      → Modify recipe to change quantity only
      → Update recipe data with the change
      → Set recipe_modified: true
      → Set change_magnitude: "minor" (only quantity changed, same ingredient)

      User: "I want a completely new recipe - chocolate fudges"
      → This is a CHANGE REQUEST (Category B)
      → Completely replace the recipe with chocolate fudges
      → Update recipe data with the new recipe
      → Set recipe_modified: true
      → Set change_magnitude: "significant" (completely different dish type requires new image)

      User: "what can I use instead of soy milk?"
      → This is a QUESTION (Category A)
      → Answer: "You can substitute soy milk with any plant-based milk like oat milk, rice milk, or coconut milk. Each will give a slightly different flavor, but they'll all work well in this recipe!"
      → Return EXACT same recipe data unchanged
      → Set recipe_modified: false
    TEXT
  end
end
