# Tool for starting image generation earlier in the workflow
# Triggers image generation asynchronously after validation, allowing it to run
# in parallel with message formatting and other post-processing steps
#
# This tool encapsulates the logic for determining when image generation is needed
# and enqueues the background job non-blocking, so it doesn't delay the response
#
# Image generation is triggered when:
# - Recipe has no image yet (first generation)
# - Recipe change is significant (ingredient changes, not just quantity adjustments)
#
# This allows images to start generating earlier in the flow, improving perceived
# performance as the image generation can happen in parallel with other operations
module Tools
  class ImageGenerationStarter
    # Starts image generation if needed
    # This is a non-blocking operation - it enqueues the job and returns immediately
    #
    # @param recipe [Recipe] The recipe to generate an image for
    # @param change_magnitude [String, nil] The magnitude of changes ("significant", "minor", or nil)
    # @return [Boolean] True if image generation was started, false otherwise
    def self.start(recipe:, change_magnitude: nil)
      # Determine if image regeneration is needed
      # Regenerate if: no image exists OR change is significant (any ingredient change, not just quantities)
      # Significant changes require new images to accurately represent the different recipe
      # Quantity-only changes (minor) don't require regeneration
      requires_regeneration = !recipe.image.attached? || change_magnitude&.downcase == "significant"

      return false unless requires_regeneration

      # Generate image asynchronously in the background
      # This allows the request to return immediately while image generation happens in parallel
      # Multiple image generation jobs can run concurrently, enabling parallelization
      # Pass force_regenerate flag if image exists but change is significant
      RecipeImageGenerationJob.perform_later(recipe.id, { force_regenerate: recipe.image.attached? })

      Rails.logger.info("ImageGenerationStarter: Enqueued image generation job for recipe #{recipe.id} (force_regenerate: #{recipe.image.attached?})")

      true
    rescue StandardError => e
      # Log error but don't fail - image generation is non-critical
      # Recipe still works without image, so we don't want to break the flow
      Rails.logger.error("ImageGenerationStarter: Failed to enqueue image generation job for recipe #{recipe.id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      false
    end
  end
end

