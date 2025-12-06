class RecipesController < ApplicationController
  before_action :set_recipe, only: %i[message destroy]

  ROLE = "user"
  DEFAULT_RECIPE_TITLE = "Untitled"
  DEFAULT_RECIPE_DESCRIPTION = "Nothing here yet..."

  # Maximum number of previous messages to include in conversation context
  # This balances context preservation with token usage and API performance
  # Most conversations stay within this limit, providing full context
  # For longer conversations, only recent messages are included
  MAX_CONVERSATION_HISTORY = 20

  # Fixed list of available appliances - user selects from these options
  # Any appliance not selected is considered unavailable and must NOT be used in recipes
  # Note: stove implies pan, so pan is not in the list
  AVAILABLE_APPLIANCES = {
    "stove" => "Stove",
    "oven" => "Oven",
    "microwave" => "Microwave",
    "blender" => "Blender",
    "stick_blender" => "Stick blender",
    "mixer" => "Mixer",
    "kettle" => "Kettle",
    "toaster" => "Toaster",
    "air_fryer" => "Air fryer",
    "pressure_cooker" => "Pressure cooker"
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
                           .order(updated_at: :desc)

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

    # Log response for debugging
    Rails.logger.info("=== Recipe Update Debug ===")
    Rails.logger.info("Response class: #{response.class}")
    Rails.logger.info("Response keys: #{response.keys.inspect}")
    Rails.logger.info("Response recipe_modified: #{response['recipe_modified'] || response[:recipe_modified]}")
    Rails.logger.info("Response message: #{response['message'] || response[:message]}")
    Rails.logger.info("Response has title: #{response.key?('title') || response.key?(:title)}")

    # Create AI message
    message_content = response["message"] || response[:message] || "Recipe generated"
    @ai_message = @chat.messages.create!(
      content: message_content,
      role: "assistant"
    )

    # Only update recipe if the LLM explicitly marked it as modified
    # The recipe_modified field tells us if the recipe data was actually changed
    # Default to true if not present (better to update unnecessarily than miss an update)
    # Handle both string and symbol keys
    recipe_data = response.except("message", "recipe_modified", "change_magnitude", :message, :recipe_modified,
                                  :change_magnitude)
    recipe_modified = response["recipe_modified"] || response[:recipe_modified]
    change_magnitude = (response["change_magnitude"] || response[:change_magnitude])&.downcase
    @recipe_changed = recipe_modified.nil? || recipe_modified == true || recipe_modified == "true"

    Rails.logger.info("Recipe changed: #{@recipe_changed}")
    Rails.logger.info("Recipe data keys: #{recipe_data.keys.inspect}")

    if @recipe_changed
      Rails.logger.info("Updating recipe with data: #{recipe_data.inspect}")
      begin
        @recipe.update!(recipe_data)
        @recipe.reload
        Rails.logger.info("Recipe updated successfully. Title: #{@recipe.title}")
      rescue StandardError => e
        Rails.logger.error("Failed to update recipe: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        raise
      end

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
    # Track timing for each phase
    timings = {}
    total_start_time = Time.current

    # Phase 1: Initial Analysis (Parallel)
    # Classify user intent and analyze conversation context
    phase1_start = Time.current
    intent_result = classify_intent(chat, user_message)
    timings[:intent_classification] = (Time.current - phase1_start) * 1000 # Convert to milliseconds

    context_start = Time.current
    conversation_context = analyze_conversation_context(chat, user_message)
    timings[:conversation_context_analysis] = (Time.current - context_start) * 1000

    # Phase 2: Conditional Link Extraction
    # Only if intent is first_message_link
    extracted_recipe_data = nil
    if intent_result[:intent] == "first_message_link" && intent_result[:detected_url].present?
      link_extraction_start = Time.current
      begin
        extracted_recipe_data = Tools::RecipeLinkExtractor.extract(intent_result[:detected_url])
        timings[:link_extraction] = (Time.current - link_extraction_start) * 1000
        Rails.logger.info("RecipeLinkExtractor: Successfully extracted recipe from #{intent_result[:detected_url]} (#{timings[:link_extraction].round(2)}ms)")
      rescue Tools::ExecutionError, Tools::InvalidInputError => e
        timings[:link_extraction] = (Time.current - link_extraction_start) * 1000
        Rails.logger.error("RecipeLinkExtractor: Failed to extract recipe: #{e.message} (#{timings[:link_extraction].round(2)}ms)")
        # Continue with normal flow - LLM will handle the URL
      end
    else
      timings[:link_extraction] = 0
    end

    # Phase 3: Recipe Generation/Modification
    # Build enhanced prompt with context and extracted data
    prompt_building_start = Time.current
    enhanced_prompt = build_enhanced_prompt(
      chat: chat,
      user_message: user_message,
      intent: intent_result,
      conversation_context: conversation_context,
      extracted_recipe_data: extracted_recipe_data
    )
    timings[:prompt_building] = (Time.current - prompt_building_start) * 1000

    # Create RubyLLM chat instance with system instructions and schema
    # Use gpt-4o for recipe generation to ensure reliable structured output
    # Tools use faster gpt-4.1-nano models, but recipe generation needs the full model
    chat_setup_start = Time.current
    ruby_llm_chat = RubyLLM.chat(model: "gpt-4.1-nano")
                           .with_instructions(system_prompt(current_user) + system_prompt_addition(chat.recipe))
                           .with_schema(RecipeSchema)
    timings[:chat_setup] = (Time.current - chat_setup_start) * 1000

    # Add conversation history from previous messages (excluding current one)
    # This provides context so the AI remembers the conversation flow
    # and doesn't repeat greetings or lose track of what was discussed
    # Only include the last MAX_CONVERSATION_HISTORY messages to control token usage
    history_start = Time.current
    build_conversation_history(chat, user_message, ruby_llm_chat)
    timings[:conversation_history_building] = (Time.current - history_start) * 1000

    # Ask with the enhanced prompt
    llm_call_start = Time.current
    llm_response = ruby_llm_chat.ask(enhanced_prompt)
    response = llm_response.content
    timings[:llm_recipe_generation] = (Time.current - llm_call_start) * 1000

    # Log response structure for debugging
    Rails.logger.info("LLM Response keys: #{response.keys.inspect}")
    Rails.logger.info("LLM Response recipe_modified: #{response['recipe_modified']}")
    Rails.logger.info("LLM Response has title: #{response.key?('title')}")
    Rails.logger.info("LLM Response has content: #{response.key?('content')}")

    # Phase 4: Validation & Auto-Fix
    # Validate recipe (allergen warnings, appliance compatibility) and automatically fix violations if recipe was modified
    validation_start = Time.current
    if [true, "true"].include?(response["recipe_modified"])
      # Validate and fix violations automatically
      response = validate_recipe(response, user_message, ruby_llm_chat)
    end
    timings[:allergen_validation] = (Time.current - validation_start) * 1000

    # Phase 5: Message Formatting
    # DISABLED: MessageFormatter takes ~2 seconds, messages were working fine without it
    # TODO: Re-enable when performance is improved or when needed for consistency
    # Format the response message using MessageFormatter tool for consistency
    # message_formatting_start = Time.current
    # formatted_message = format_response_message(
    #   recipe_data: response,
    #   conversation_context: conversation_context,
    #   intent: intent_result,
    #   changes_made: {
    #     recipe_modified: response["recipe_modified"] || false,
    #     allergens_added: detect_allergens_added(response, user_message)
    #   }
    # )
    # # Replace the message in response with formatted message
    # response["message"] = formatted_message[:message] if formatted_message[:message]
    # timings[:message_formatting] = (Time.current - message_formatting_start) * 1000
    timings[:message_formatting] = 0

    # Calculate total time and log all timings
    total_time = (Time.current - total_start_time) * 1000
    timings[:total] = total_time

    # Log detailed timing breakdown
    Rails.logger.info("=" * 80)
    Rails.logger.info("Recipe Generation Performance Breakdown:")
    Rails.logger.info("  Intent Classification:        #{timings[:intent_classification].round(2)}ms")
    Rails.logger.info("  Context Analysis:             #{timings[:conversation_context_analysis].round(2)}ms")
    Rails.logger.info("  Link Extraction:              #{timings[:link_extraction].round(2)}ms")
    Rails.logger.info("  Prompt Building:              #{timings[:prompt_building].round(2)}ms")
    Rails.logger.info("  Chat Setup:                    #{timings[:chat_setup].round(2)}ms")
    Rails.logger.info("  Conversation History Building: #{timings[:conversation_history_building].round(2)}ms")
    Rails.logger.info("  LLM Recipe Generation:        #{timings[:llm_recipe_generation].round(2)}ms (#{(timings[:llm_recipe_generation] / total_time * 100).round(1)}% of total)")
    Rails.logger.info("  Allergen Validation:           #{timings[:allergen_validation].round(2)}ms")
    # Rails.logger.info("  Message Formatting:            #{timings[:message_formatting].round(2)}ms") # DISABLED
    Rails.logger.info("  " + ("-" * 78))
    Rails.logger.info("  TOTAL TIME:                    #{total_time.round(2)}ms")
    Rails.logger.info("=" * 80)

    response
  end

  # Classifies user intent using IntentClassifier tool
  def classify_intent(chat, user_message)
    # Build conversation history text
    conversation_history = build_conversation_history_text(chat, user_message)

    # Build current recipe state
    current_recipe_state = if chat.recipe && recipe_has_content?(chat.recipe)
                             "Title: #{chat.recipe.title}\nDescription: #{chat.recipe.description}"
                           else
                             ""
                           end

    # Classify intent
    classifier = Tools::IntentClassifier.new
    classifier.execute(
      user_message: user_message.content,
      conversation_history: conversation_history,
      current_recipe_state: current_recipe_state
    )
  end

  # Analyzes conversation context using ConversationContextAnalyzer tool
  def analyze_conversation_context(chat, user_message)
    # Build conversation history text
    conversation_history = build_conversation_history_text(chat, user_message)

    # Analyze context
    analyzer = Tools::ConversationContextAnalyzer.new
    analyzer.execute(conversation_history: conversation_history)
  end

  # Builds conversation history as formatted text
  def build_conversation_history_text(chat, user_message)
    previous_messages = chat.messages
                            .where.not(id: user_message.id)
                            .order(:created_at)
                            .limit(MAX_CONVERSATION_HISTORY)

    previous_messages.map do |message|
      "#{message.role.capitalize}: #{message.content}"
    end.join("\n")
  end

  # Builds enhanced prompt with context and extracted data
  def build_enhanced_prompt(chat: nil, user_message:, intent: nil, conversation_context: {}, extracted_recipe_data: {}) # rubocop:disable Lint/UnusedMethodArgument
    parts = []

    # Add extracted recipe data if available
    if extracted_recipe_data
      parts << "EXTRACTED RECIPE DATA FROM URL:"
      parts << "Title: #{extracted_recipe_data[:title]}"
      parts << "Description: #{extracted_recipe_data[:description]}" if extracted_recipe_data[:description].present?
      if extracted_recipe_data[:ingredients].any?
        parts << "Ingredients: #{extracted_recipe_data[:ingredients].join(', ')}"
      end
      if extracted_recipe_data[:instructions].any?
        parts << "Instructions: #{extracted_recipe_data[:instructions].join(' | ')}"
      end
      parts << "\nPlease structure this recipe according to user preferences and requirements."
      parts << ""
    end

    # Add conversation context hints
    if conversation_context[:greeting_needed] == false
      parts << "NOTE: This is a follow-up message. Do NOT include a greeting - get straight to the point."
    end

    if conversation_context[:recent_changes].any?
      parts << "Recent changes made: #{conversation_context[:recent_changes].join(', ')}"
    end

    # Add user message
    parts << user_message.content

    parts.join("\n")
  end

  # Validates recipe and automatically fixes violations
  # Validates both allergen warnings and appliance compatibility
  # Uses RecipeFixService to implement a validation loop that fixes violations
  #
  # @param response [Hash] LLM response with recipe data
  # @param user_message [Message] User message that triggered recipe generation
  # @param ruby_llm_chat [RubyLLM::Chat] RubyLLM chat instance with conversation history
  # @return [Hash] Fixed recipe data (or original if no violations)
  def validate_recipe(response, user_message, ruby_llm_chat)
    # Collect all violations from different validators
    all_violations = []
    all_fix_instructions = []

    # Validate allergen warnings
    allergen_validation_result = validate_allergen_warnings_internal(response, user_message)
    all_violations.concat(allergen_validation_result.violations) if allergen_validation_result
    if allergen_validation_result && allergen_validation_result.fix_instructions.present?
      all_fix_instructions << allergen_validation_result.fix_instructions
    end

    # Validate appliance compatibility
    appliance_validation_result = validate_appliance_compatibility_internal(response)
    all_violations.concat(appliance_validation_result.violations) if appliance_validation_result
    if appliance_validation_result && appliance_validation_result.fix_instructions.present?
      all_fix_instructions << appliance_validation_result.fix_instructions
    end

    # If no violations, return original response
    return response if all_violations.empty?

    # Log all violations found
    Rails.logger.warn("Recipe Validation: Found #{all_violations.length} total violation(s)")
    all_violations.each_with_index do |violation, idx|
      Rails.logger.warn("  #{idx + 1}. #{violation[:type]}: #{violation[:message]}")
    end
    Rails.logger.warn("  Combined fix instructions:\n#{all_fix_instructions.join("\n\n")}")

    # Attempt to fix violations automatically
    Rails.logger.info("RecipeFixService: Attempting to fix violations automatically")
    RecipeFixService.fix_violations(
      recipe_data: response,
      violations: all_violations,
      user_message: user_message,
      chat: @chat,
      current_user: current_user,
      ruby_llm_chat: ruby_llm_chat
    )
  end

  # Validates allergen warnings (internal method)
  #
  # @param response [Hash] LLM response with recipe data
  # @param user_message [Message] User message
  # @return [ValidationResult] Validation result
  def validate_allergen_warnings_internal(response, user_message)
    # Extract instructions from response
    instructions = response.dig("content", "instructions") || []

    # Extract requested ingredients from user message
    requested_ingredients = extract_requested_ingredients(user_message.content)

    # Get user allergies (convert hash to array of active allergy keys)
    user_allergies = if current_user.allergies.is_a?(Hash)
                       current_user.active_allergies
                     else
                       # Legacy format - parse as comma-separated string
                       parse_user_field(current_user.allergies)
                     end

    # Validate
    Tools::AllergenWarningValidator.validate(
      instructions: instructions,
      user_allergies: user_allergies,
      requested_ingredients: requested_ingredients
    )
  end

  # Validates appliance compatibility (internal method)
  #
  # @param response [Hash] LLM response with recipe data
  # @return [ValidationResult] Validation result
  def validate_appliance_compatibility_internal(response)
    # Extract instructions from response
    instructions = response.dig("content", "instructions") || []

    # Get user appliances (convert hash to array of active appliance keys)
    available_appliances = if current_user.appliances.is_a?(Hash)
                             current_user.active_appliances
                           else
                             # Legacy format - parse as comma-separated string
                             parse_user_field(current_user.appliances)
                           end.map(&:downcase)

    # Calculate unavailable appliances
    unavailable_appliances = AVAILABLE_APPLIANCES.keys.reject { |key| available_appliances.include?(key.downcase) }

    # Validate
    Tools::ApplianceCompatibilityChecker.validate(
      instructions: instructions,
      available_appliances: available_appliances,
      unavailable_appliances: unavailable_appliances
    )
  end

  # Extracts requested ingredients from user message (basic implementation)
  def extract_requested_ingredients(message)
    # Simple pattern matching for common phrases
    # Stops at filler words to avoid capturing phrases like "sesame anyway"
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

  # Formats response message using MessageFormatter tool
  #
  # @param recipe_data [Hash] The recipe data
  # @param conversation_context [Hash] Context from ConversationContextAnalyzer
  # @param intent [String] User intent from IntentClassifier
  # @param changes_made [Hash] Summary of changes made
  # @return [Hash] Formatted message with metadata
  def format_response_message(recipe_data:, conversation_context:, intent:, changes_made: {})
    Tools::MessageFormatter.format(
      recipe_data: recipe_data,
      conversation_context: conversation_context,
      intent: intent,
      changes_made: changes_made
    )
  rescue StandardError => e
    Rails.logger.error("MessageFormatter failed: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    # Fallback to original message or default
    {
      message: recipe_data["message"] || recipe_data[:message] || "Recipe updated successfully.",
      tone: "friendly",
      includes_greeting: false,
      change_summary: "Recipe updated"
    }
  end

  # Detects if allergens were added to the recipe
  #
  # @param _recipe_data [Hash] Recipe data (unused, kept for API consistency)
  # @param user_message [Message] User message
  # @return [Boolean] True if allergens were likely added
  def detect_allergens_added(_recipe_data, user_message)
    return false unless current_user && current_user.active_allergies.any?

    # Extract requested ingredients
    requested_ingredients = extract_requested_ingredients(user_message.content)
    return false if requested_ingredients.empty?

    # Check if any requested ingredients match user allergies
    user_allergies = current_user.active_allergies
    requested_ingredients.any? do |ingredient|
      ingredient_lower = ingredient.downcase
      user_allergies.any? do |allergy|
        ingredient_lower.include?(allergy.downcase) || allergy.downcase.include?(ingredient_lower)
      end
    end
  end

  # Adds conversation history to RubyLLM chat instance
  # Only includes the last MAX_CONVERSATION_HISTORY messages to control token usage
  # Maintains chronological order by ordering by created_at
  def build_conversation_history(chat, current_user_message, ruby_llm_chat)
    # Get the last MAX_CONVERSATION_HISTORY messages (excluding the current one)
    # Order by created_at to maintain chronological conversation flow
    previous_messages = chat.messages
                            .where.not(id: current_user_message.id)
                            .order(:created_at)
                            .limit(MAX_CONVERSATION_HISTORY)

    # Add each message to the RubyLLM chat instance
    # This builds up the conversation context for the LLM
    # Convert Message objects to hash format with role and content keys
    previous_messages.each do |message|
      ruby_llm_chat.add_message(role: message.role, content: message.content)
    end
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
      - If the user EXPLICITLY requested an allergen (e.g., "add peanuts" when user is allergic to peanuts):#{' '}
        * Include it as requested
        * ⚠️ ABSOLUTELY MANDATORY: You MUST add a prominent, personalized WARNING with the warning emoji (⚠️) in the INSTRUCTION STEP where the allergen is added
        * The warning MUST be in the instructions array, specifically in the step where you add the allergen ingredient
        * The warning MUST be personalized to the user's specific allergy - mention the exact allergen from their allergy list
        * The warning MUST include the warning emoji (⚠️) - this is REQUIRED, not optional
        * Format: "⚠️ WARNING: This step contains [specific allergen name] which you are allergic to. Proceed with extreme caution"
        * Example: If user is allergic to "nuts" and requests peanuts, and you add peanuts in step 1, the instruction must say: "⚠️ WARNING: This step contains peanuts (nuts) which you are allergic to. Proceed with extreme caution. In a large mixing bowl, combine the whole wheat flour, protein powder, baking powder, and chopped peanuts."
        * CRITICAL: Use ONLY the clean allergen/ingredient name in the warning - do NOT include filler words from the user's message (e.g., if user says "add sesame anyway", use "sesame" not "sesame anyway")
        * CRITICAL: Do NOT duplicate "Proceed with extreme caution" - it should appear only once in the warning
        * The warning MUST appear in the SAME instruction step where the allergen is added - it is NOT optional, it is MANDATORY
        * The warning emoji (⚠️) MUST be included - do NOT omit it
        * The word "WARNING" MUST be capitalized - use "⚠️ WARNING:" not "⚠️ warning:" or "⚠️ Warning:"
        * Do NOT use generic warnings like "common allergen" - it MUST be personalized to the user's specific allergy
        * CRITICAL: Before returning the recipe, verify that the warning with emoji (⚠️) and capitalized "WARNING:" is actually in the instruction step where the allergen is added
      - If allergens were removed/substituted (not explicitly requested): Document what was removed/substituted for transparency
      - If allergens were included with warning (explicitly requested): The warning with emoji (⚠️) and capitalized "WARNING:" in the instruction step where the allergen is added is ABSOLUTELY MANDATORY and must be personalized

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
      - ⚠️ ABSOLUTELY CRITICAL: If an allergen was explicitly requested by the user, you MUST verify that:
        * A personalized warning WITH the warning emoji (⚠️) and capitalized "WARNING:" is included in the INSTRUCTION STEP where the allergen is added
        * The warning emoji (⚠️) is present - check that it's actually there
        * The word "WARNING" is capitalized - use "⚠️ WARNING:" format
        * The warning mentions the specific allergen from the user's allergy list (not generic)
        * The warning is in the same instruction step where the allergen ingredient is mentioned
        * If the warning with emoji and capitalized "WARNING:" is missing from the instruction step, you MUST add it before returning the recipe
      - Ensure the recipe is complete, coherent, and cookable
      - Confirm shopping list matches all ingredients needed
      - Verify message accurately reflects any adjustments made

      STEP 3: MESSAGE GENERATION
      Your message should maintain the user's preferred persona (see preferences) while being factual about adjustments.#{' '}

      ⚠️ CRITICAL: CONVERSATION CONTEXT AWARENESS
      - You have access to the full conversation history - use it to understand the context
      - If this is a follow-up message in an ongoing conversation, DO NOT start with a greeting like "Hello chef!" or "Here's a delightful recipe"
      - Only greet the user on the FIRST message of a conversation (when there are no previous messages)
      - For follow-up messages, be conversational and reference the ongoing discussion naturally
      - Examples:
        * First message: "Hello chef! Here's a delightful recipe for..."
        * Follow-up: "I've added [ingredient] as you requested..." (no greeting, get straight to the point)
        * Follow-up: "Great question! The cooking time is..." (no greeting, answer directly)

      Message Structure (for FIRST message only):
      1. Start with an encouraging, friendly greeting and introduction about the recipe
      2. If you made actual adjustments, mention them factually and specifically
      3. End with an encouraging note about enjoying the recipe
      4. Add a line break, then add: "Let me know if you need any adjustments!"

      Message Structure (for FOLLOW-UP messages):
      1. Get straight to the point - no greeting needed
      2. If answering a question: Answer directly and helpfully
      3. If making changes: State what you changed factually and specifically
      4. If adding allergen with warning: Mention the addition and that a personalized warning is in the recipe
      5. End with: "Let me know if you need any adjustments!"

      Rules for mentioning adjustments (ONLY mention if you actually made changes):
      - If you removed or substituted allergy ingredients FROM THE ORIGINAL RECIPE: State which ingredients were avoided and what substitutes were used (e.g., "I've removed [allergen ingredient] and used [substitute] instead to keep it safe for you")
      - If the user explicitly requested an allergen and you added it with a warning:#{' '}
        * State that you've added it as requested
        * Mention that a personalized warning is included in the instruction step where it's added
        * Example: "I've added [allergen] as you requested. Please note there's a personalized warning in the instruction step where it's added about your allergy to [specific allergen name]."
        * The warning in the instruction step is MANDATORY and must be personalized to the user's specific allergy
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
    # Get active allergies from hash format
    active_allergies = if user.allergies.is_a?(Hash)
                         user.allergies.select { |_key, value| value == true }.keys
                       else
                         # Legacy format - parse as comma-separated string
                         parse_user_field(user.allergies)
                       end

    if active_allergies.any?
      # Format allergy names for display (e.g., "tree_nuts" -> "Tree nuts")
      allergies_list = active_allergies.map do |key|
        formatted_name = key.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
        "- #{formatted_name}"
      end.join("\n")

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
    # Get user appliances (convert hash to array of active appliance keys)
    available_appliances = if user.appliances.is_a?(Hash)
                             user.active_appliances
                           else
                             # Legacy format - parse as comma-separated string
                             parse_user_field(user.appliances)
                           end.map(&:downcase)

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

      WHAT THE USER HAS (ASSUMED BASIC EQUIPMENT):
      - Basic kitchen utensils: knives, cutting boards, bowls, spoons, forks, measuring cups/spoons, spatulas, whisks, etc.
      - Pans and pots: If the user has "stove" selected, they have basic pans and pots for stovetop cooking (this is implied by stove)
      - Basic storage containers: bowls, plates, containers for ingredients

      WHAT THE USER DOES NOT HAVE (DO NOT ASSUME):
      - Do NOT assume any specialized equipment beyond what's explicitly listed in AVAILABLE APPLIANCES above
      - Do NOT assume stand mixers, food processors, blenders, or any other appliances unless explicitly listed
      - Do NOT assume specialized tools like mandolines, spiralizers, pasta makers, etc. unless explicitly listed
      - Do NOT assume any cooking equipment beyond basic utensils and the selected appliances
      - If a recipe requires equipment not in the AVAILABLE list, you MUST adapt it to use only available appliances and basic utensils

      CRITICAL RULES:
      - You MUST ONLY use appliances from the AVAILABLE list above
      - You MUST NEVER use any appliance from the UNAVAILABLE list above
      - You can assume basic kitchen utensils (knives, bowls, spoons, etc.) and pans/pots if stove is available
      - You MUST NOT assume any other specialized equipment beyond what's explicitly selected
      - If a recipe requires an unavailable appliance, you MUST completely rebuild or adapt the recipe to use ONLY available appliances and basic utensils
      - This is MANDATORY and NON-NEGOTIABLE - recipes that require unavailable appliances are NOT acceptable
      - If a recipe cannot be made with available appliances, you MUST find alternative cooking methods or rebuild the recipe entirely
      - The recipe MUST be fully executable using ONLY the user's available equipment and basic utensils - no exceptions
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
      - If the user requests an ingredient they're allergic to:#{' '}
        * Include it as requested
        * ⚠️ ABSOLUTELY MANDATORY: Add a personalized WARNING WITH the warning emoji (⚠️) and capitalized "WARNING:" in the INSTRUCTION STEP where the allergen is added
        * The warning MUST be in the instructions array, in the same step where you add the allergen ingredient
        * The warning MUST include the warning emoji (⚠️) - this is REQUIRED
        * The word "WARNING" MUST be capitalized - use "⚠️ WARNING:" format
        * The warning MUST mention the specific allergen from the user's allergy list
        * Format: "⚠️ WARNING: This step contains [specific allergen name] which you are allergic to. Proceed with extreme caution. [rest of instruction]"
        * The warning MUST be placed at the BEGINNING of the instruction step where the allergen is added
        * This warning with emoji and capitalized "WARNING:" is NOT optional - it MUST be included in the instruction step
        * CRITICAL: Before returning, verify the warning with emoji (⚠️) and capitalized "WARNING:" is actually in the instruction step where the allergen is added
      - Make ONLY the changes the user requested
      - Update the recipe fields (title, description, content, shopping_list) with the modified recipe
      - ⚠️ ABSOLUTELY CRITICAL: If you added an allergen, the warning WITH emoji (⚠️) and capitalized "WARNING:" MUST be in the instruction step where the allergen is added - verify it's there with the emoji and capitalized "WARNING:" before returning
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
      → Answer: "Yes! The pancakes will cook perfectly using the kettle-steaming method. The steam will cook them through, creating fluffy, tender pancakes. Just make sure to steam them for the full time indicated in the instructions." (NO greeting - this is a follow-up question)
      → Return EXACT same recipe data unchanged
      → Set recipe_modified: false

      User: "add chocolate chips"
      → This is a CHANGE REQUEST (Category B)
      → Modify recipe to include chocolate chips
      → Update recipe data with the change
      → Set recipe_modified: true
      → Set change_magnitude: "significant" (adding an ingredient requires image regeneration)
      → Message: "I've added chocolate chips as you requested. [rest of message]" (NO greeting - this is a follow-up)

      User: "add peanuts" (when user is allergic to nuts)
      → This is a CHANGE REQUEST (Category B)
      → Modify recipe to include peanuts
      → ⚠️ ABSOLUTELY MANDATORY: Add personalized warning WITH emoji (⚠️) and capitalized "WARNING:" to the INSTRUCTION STEP where peanuts are added: "⚠️ WARNING: This step contains peanuts (nuts) which you are allergic to. Proceed with extreme caution. [rest of instruction]"
      → The warning emoji (⚠️) and capitalized "WARNING:" MUST be included - verify it's in the instruction step where the allergen is added
      → Update recipe data with the change AND the warning WITH emoji and capitalized "WARNING:" in the instruction step
      → Set recipe_modified: true
      → Set change_magnitude: "significant"
      → Message: "I've added peanuts as you requested. Please note there's a personalized warning in the instruction step where it's added about your allergy to nuts." (NO greeting - this is a follow-up)
      → ⚠️ CRITICAL: The warning WITH emoji (⚠️) and capitalized "WARNING:" MUST be in the instruction step where the allergen is added, not in the description field
      → Before returning, verify the instruction step contains: "⚠️ WARNING: This step contains peanuts (nuts) which you are allergic to. Proceed with extreme caution."

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
