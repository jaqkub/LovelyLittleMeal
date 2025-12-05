# Background job for generating recipe images asynchronously using RubyLLM.paint
# This allows image generation to happen in parallel without blocking the main request
# Multiple jobs can run concurrently, enabling parallelization of image generation
#
# The job generates an image based on the final recipe data (title, description, ingredients)
# to ensure the image accurately represents the recipe after all validations and adjustments
class RecipeImageGenerationJob < ApplicationJob
  # Queue name for organizing jobs (optional, defaults to 'default')
  queue_as :default

  # Retry configuration: retry up to 3 times with polynomial backoff
  # Image generation failures are retried since they're non-critical but improve UX
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # Discard job if recipe no longer exists (user deleted it)
  discard_on ActiveRecord::RecordNotFound

  # Perform the image generation job
  # This method is called by ActiveJob when the job is executed
  #
  # @param recipe_id [Integer] The ID of the recipe to generate an image for
  # @param options [Hash] Optional parameters for image generation (size, quality, style, model, force_regenerate)
  def perform(recipe_id, options = {})
    recipe = Recipe.find(recipe_id)

    # Skip if image already exists and regeneration is not forced
    # This prevents regenerating images unnecessarily for minor changes
    # force_regenerate: true allows regeneration even if image exists (for significant recipe changes)
    if recipe.image.attached? && !options.fetch(:force_regenerate, false)
      return
    end

    # If forcing regeneration, purge the old image first
    # This ensures we don't accumulate old images and the new image replaces the old one
    if options.fetch(:force_regenerate, false) && recipe.image.attached?
      recipe.image.purge
    end

    # Build a descriptive prompt from the recipe data
    # The prompt is constructed from title, description, and key ingredients
    # to create an accurate visual representation of the recipe
    prompt = build_image_prompt(recipe)

    # Generate image using RubyLLM.paint
    # RubyLLM.paint supports DALL-E 3 and other image generation models
    # It returns a URL or base64 encoded image data
    # Based on RubyLLM documentation, paint takes prompt and optional model parameter
    # Other parameters like size, quality, style may need to be passed differently or aren't supported
    image_result = RubyLLM.paint(
      prompt,
      model: options.fetch(:model, "dall-e-3")
    )

    # Handle the response - RubyLLM.paint may return URL or base64 data
    image_data = extract_image_data(image_result)
    return unless image_data

    # Download the image if it's a URL, or decode if it's base64
    image_file = download_or_decode_image(image_data)
    return unless image_file

    # Attach the generated image to the recipe using Active Storage
    # This saves the image to the configured storage service (local, S3, etc.)
    recipe.image.attach(
      io: image_file,
      filename: "recipe_#{recipe.id}_#{Time.current.to_i}.png",
      content_type: "image/png"
    )

    # Clean up tempfile
    image_file.close
    image_file.unlink

    # Reload recipe to ensure we have the latest image attachment data
    recipe.reload

    # Broadcast Turbo Stream update to refresh the image in the view
    # This allows the image to appear without requiring a page refresh
    broadcast_image_update(recipe)
  rescue StandardError => e
    # Log error for debugging
    # Image generation failures are non-critical - recipe still works without image
    Rails.logger.error("RecipeImageGenerationJob failed for recipe #{recipe_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))

    # Re-raise to trigger retry mechanism
    raise
  end

  private

  # Build a descriptive prompt for image generation based on recipe details
  # Creates a prompt that will generate an appetizing, accurate food image
  #
  # @param recipe [Recipe] The recipe to build a prompt for
  # @return [String] The image generation prompt
  def build_image_prompt(recipe)
    # Extract key information from recipe
    title = recipe.title.presence || "a delicious recipe"
    description = recipe.description.presence || ""
    ingredients = recipe.content&.dig("ingredients") || []

    # Build a rich prompt for food photography
    # Include title, description, and key ingredients for accuracy
    # CRITICAL: Never add any text on the image - this ensures clean food photography
    prompt_parts = [
      "Professional food photography of",
      title,
      description.present? ? ", #{description.downcase}" : "",
      ingredients.any? ? ". Featuring #{ingredients.first(3).join(', ')}" : "",
      ". High quality, appetizing, well-lit, restaurant style food photography",
      ". CRITICAL: Do not add any text, labels, or words on the image - only the food itself"
    ]

    prompt_parts.join(" ").strip
  end

  # Extract image data from RubyLLM.paint response
  # RubyLLM.paint returns a RubyLLM::Image object with url or data methods
  #
  # @param result [RubyLLM::Image, Hash, String] The result from RubyLLM.paint
  # @return [String, nil] The image URL or base64 data, or nil if not found
  def extract_image_data(result)
    # Handle RubyLLM::Image object (most common case)
    if result.respond_to?(:url)
      # RubyLLM::Image object - get the URL
      url = result.url
      return url if url.present?
    end

    if result.respond_to?(:data)
      # RubyLLM::Image object with data method
      data = result.data
      return data if data.present?
    end

    # Handle other formats
    case result
    when String
      # Direct URL or base64 string
      result
    when Hash
      # Structured response - check common keys
      result["url"] || result[:url] || result["data"] || result[:data] || result.dig("data", 0,
                                                                                     "url") || result.dig("data", 0,
                                                                                                          "b64_json")
    when Array
      # Array of results - take first
      return nil if result.empty?

      extract_image_data(result.first)
    else
      Rails.logger.warn("Unexpected image generation result format: #{result.class}")
      nil
    end
  end

  # Download image from URL or decode base64 data
  # Returns a Tempfile with the image data
  #
  # @param image_data [String] URL or base64 encoded image data
  # @return [Tempfile, nil] The image file or nil on failure
  def download_or_decode_image(image_data)
    require "net/http"
    require "tempfile"
    require "base64"
    require "uri"

    # Handle base64 encoded images
    # Check for data URI format or pure base64 string
    if image_data.start_with?("data:image") || (image_data.length > 100 && image_data.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z}))
      # Base64 encoded image
      base64_data = image_data.start_with?("data:image") ? image_data.split(",")[1] : image_data
      image_binary = Base64.decode64(base64_data)

      tempfile = Tempfile.new(["recipe_image", ".png"])
      tempfile.binmode
      tempfile.write(image_binary)
      tempfile.rewind
      tempfile
    else
      # URL-based image - try using open-uri first (simpler, handles redirects)
      # Fall back to Net::HTTP if open-uri fails
      begin
        require "open-uri"
        downloaded_file = URI.open(image_data, "User-Agent" => "Ruby/Rails", "Accept" => "image/*", read_timeout: 30)
        tempfile = Tempfile.new(["recipe_image", ".png"])
        tempfile.binmode
        tempfile.write(downloaded_file.read)
        tempfile.rewind
        downloaded_file.close
        tempfile
      rescue StandardError => e
        Rails.logger.warn("open-uri failed, trying Net::HTTP: #{e.message}")
        
        # Fallback to Net::HTTP
        uri = URI.parse(image_data)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = 30

        # Build request with full URI (including query parameters if present)
        request_path = uri.path
        request_path += "?#{uri.query}" if uri.query
        request = Net::HTTP::Get.new(request_path)
        
        # Add headers that might be required
        request["User-Agent"] = "Ruby/Rails"
        request["Accept"] = "image/*"

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error("Failed to download image: HTTP #{response.code} - #{response.message}")
          Rails.logger.error("URL: #{image_data}")
          Rails.logger.error("Response body: #{response.body[0..500]}") if response.body
          raise StandardError, "Failed to download image: HTTP #{response.code} - #{response.message}"
        end

        tempfile = Tempfile.new(["recipe_image", ".png"])
        tempfile.binmode
        tempfile.write(response.body)
        tempfile.rewind
        tempfile
      end
    end
  rescue StandardError => e
    Rails.logger.error("Failed to process image data: #{e.message}")
    nil
  end

  # Broadcast Turbo Stream update to refresh the image in the UI
  # This allows the image to appear without requiring a page refresh
  #
  # @param recipe [Recipe] The recipe that was updated
  def broadcast_image_update(recipe)
    # Use Turbo Streams to update the image in the view
    # This will replace the loading placeholder with the actual image
    # The stream is broadcast to all users viewing this recipe
    Turbo::StreamsChannel.broadcast_replace_to(
      "recipe_#{recipe.id}",
      target: "recipe-image-#{recipe.id}",
      partial: "recipes/image",
      locals: { recipe: recipe }
    )
  rescue StandardError => e
    # Log but don't fail - image is attached even if broadcast fails
    Rails.logger.warn("Failed to broadcast image update: #{e.message}")
  end
end
